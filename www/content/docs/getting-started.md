+++
title = "Getting Started"
description = "Set up the tools, write a counter, test it natively, and run it in a browser."
weight = 3
template = "page.html"
+++

# Getting Started

By the end of this page you will have written a counter, tested it without a
browser, and run it as WebAssembly.

## Set up

Roc Signals has no published release yet, so you work in a checkout of
[the repository](https://github.com/lukewilliamboswell/roc-signals).

You need the current Roc nightly installed as `roc` (from
[roc-lang/nightlies](https://github.com/roc-lang/nightlies/releases)): the
platform is always tested against the latest nightly. Every other tool is
pinned with [Blueprint](https://github.com/lukewilliamboswell/roc-blueprint):
Zig, Node and the scripts' own Roc (`roc-stable`). Install the `blueprint`
release that `Blueprint.roc` names, then open a shell with the pinned tools
on `PATH`:

```sh
blueprint shell
```

Running specs in a browser also needs Google Chrome installed as
`google-chrome`.

## The files of an app

An app is a directory with one module that describes the UI and two thin
entry points, one per platform:

| File | Purpose |
|---|---|
| `Counter.roc` | The app: its state, view and `program` |
| `main-web.roc` | The browser build, on `platform/main.roc` |
| `main-test.roc` | The native spec runner, on `platform/test.roc` |
| `specs/*.scm` | Specs, run by both runners |

This page's counter lives in `www/samples/counter/`. Put your own app in a new
directory beside `examples/`, and adjust the relative platform paths to match.

## Write the app

{{ sample(file="counter/Counter.roc") }}

`Engine.state(0, Counter.view)` creates a piece of state with the initial value
`0` and passes its handle to `view`. Inside `view`:

- `count.val()` is the state's current value. `.map` turns it into the text
  the `span` shows. The engine re-evaluates that text only when `count`
  changes.
- `count.update(|n| n + 1)` is a *handler*: a reducer the engine applies when
  the button is clicked.
- `Ctx` names the *context* the view runs in: inside one state of type `I64`
  at the root. Every value, state handle and element is typed by the context it
  belongs to, so a value can never be read where it does not exist.
- `Html.aria_label` gives each button an accessible name, which is also how
  specs find it.

`program` is the one value both entry points use.

## The entry points

The browser build names the web platform:

{{ sample(file="counter/main-web.roc") }}

The test build names the test platform and the spec runner from
`test-support/`:

{{ sample(file="counter/main-test.roc") }}

Type-check the app:

```sh
roc check www/samples/counter/main-web.roc
```

## Test it natively

A spec describes what a user does and sees, located the way a screen reader
would find things:

{{ sample(file="counter/specs/counter.scm", syntax="scheme") }}

Prepare the test platform once, then build the runner and run the specs:

```sh
blueprint run platform-test
roc build www/samples/counter/main-test.roc --output=counter-specs
./counter-specs spec www/samples/counter/specs/*.scm
```

Each spec reports one JSON line, and a summary follows. The runner drives the
real engine and checks the DOM it would build, so this takes milliseconds.
[Testing](@/docs/testing.md) covers the spec language and the Chrome replay.

## Run it in a browser

A page loads the app with the platform's runtime, `platform/runtime.mjs`:

{{ sample(file="counter/index.html", syntax="html") }}

Build the platform's Wasm host, then put the page, the runtime and the app in
one directory and serve it:

```sh
blueprint run bundle
mkdir -p counter-site
cp www/samples/counter/index.html platform/runtime.mjs counter-site/
roc build --target=wasm32 www/samples/counter/main-web.roc --output=counter-site/app.wasm
blueprint run serve -- counter-site
```

Open the address it prints. If the app breaks a contract, `onFault` receives
the classified diagnostic; [Under the Hood](@/docs/under-the-hood.md#when-something-goes-wrong)
explains what each class means.

## Next

Read [Thinking in Signals](@/docs/thinking-in-signals.md) for the model, then
build the [Tutorial](@/docs/tutorial.md) app.
