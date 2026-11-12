+++
title = "Getting Started"
description = "Create a counter with signals.roc, run it in a browser, test it natively, and build it for deployment."
weight = 2
template = "page.html"
+++

# Getting Started

By the end of this page you will have created a counter, changed it while it
runs in a browser, tested it without a browser, and built it for
deployment.

## Set up

First open the [current Roc Signals release notes](https://github.com/lukewilliamboswell/roc-signals/releases/latest).
Under **Compilers**, find the Roc nightly that release was built and tested
with. Install that nightly from
[roc-lang/nightlies](https://github.com/roc-lang/nightlies/releases) and put
its `roc` executable on your `PATH`.

Check the installed version before downloading the tool:

```sh
roc version
```

The version should match the nightly named in the Signals release notes.
Those notes also describe any compiler or dependency limitations affecting
the release; a newer nightly may behave differently.

Every release also publishes `signals.roc`, a small Roc program that
creates, serves, builds and tests an app. Download it and create an app:

```sh
curl -fLO https://github.com/lukewilliamboswell/roc-signals/releases/latest/download/signals.roc
roc signals.roc init counter
cd counter
```

`roc` downloads what `signals.roc` needs the first time it runs: the
roc-signals package it names, and the basic-cli platform it runs on.
`roc signals.roc help` lists the commands and says which release and
nightly you have.

## The files of an app

`init` writes a counter, the same one this page explains:

| File | Purpose |
|---|---|
| `signals.roc` | The tool, which runs `init`, `serve`, `build` and `test` |
| `Counter.roc` | The app: its state, view and `program` |
| `main.roc` | The entry point, which names the platform: it builds for the browser and as the native spec runner |
| `index.html` | The page that mounts the app |
| `specs/counter.scm` | A spec, run by `test` |
| `.gitignore` | Keeps build output (`.signals/` and `dist/`) out of version control |

## Write the app

{{ sample(file="counter/Counter.roc") }}

`Engine.state(0, Counter.view)` creates a piece of *local state* with the
initial value `0` and passes its handle to `view`. Inside `view`:

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

`view` runs once, when the app starts. It does not run again on a click: the
engine applies the reducer and rewrites the one text that reads `count`.

The count is local state because only the counter cares about it. State that
several parts of an app share lives in a store instead, and
[Thinking in Signals](@/docs/thinking-in-signals.md) says how to choose.

`program` is the value the entry point binds.

## The entry point

`main.roc` names the platform and binds the app's `program` as `main`:

The example uses `<package release URL here>` as a placeholder. Keep the
actual platform URL that `init` wrote in your file. If writing an entry
point by hand, use the platform bundle URL from the
[Roc Signals release notes](https://github.com/lukewilliamboswell/roc-signals/releases/latest).

{{ sample(file="counter/main.roc") }}

The platform builds this one file for two kinds of target:
`--target=wasm32` gives the module the browser runs, and your system's
native target gives the app's native spec runner: `x64musl` on Linux,
`arm64mac` or `x64mac` on macOS, `x64win` on Windows. `signals.roc` makes
both builds for you, choosing the native target for the machine it runs
on.

## Run it in a browser

```sh
roc signals.roc serve
```

```text
Building the app...
Serving the app at http://127.0.0.1:8000/ (press Ctrl-C to stop). Pages reload when you save a change, and show build errors over the app.
```

Between the two lines it says how long the build took. Open the address.
The page is your `index.html`, which loads the app with the platform's
runtime:

{{ sample(file="counter/index.html", syntax="html") }}

The server supplies `runtime.mjs` (with `worker.mjs`, which the runtime
starts [workers](@/docs/workers.md) from) and `app.wasm`, the app's
development build; your other files are served as they are. When port 8000
is taken it uses the next free one and says so; `--port N` chooses another.

Now change the initial value in `Counter.roc` from `0` to `10`, and save.
The server rebuilds the app and the page reloads, showing `10`. Reloading
starts the app afresh: nothing of the running app is carried across a
change. If the build fails, the compiler's report appears over the page,
which keeps the last build that worked, and the terminal shows it too; fix
the error and save, and the page reloads. An error that stops the page from
mounting the app, and a fault the engine contains while it runs, appear the
same way. A change to any other file, such as `index.html`, reloads the page
without a build. The script that does this is added to the page as the
server sends it; your `index.html` is never changed.

If the app breaks a contract, `onFault` receives the classified diagnostic;
[Under the Hood](@/docs/under-the-hood.md#when-something-goes-wrong)
explains what each class means.

## Test it

Use another terminal in the `counter` directory while the development server
runs, or stop it with Ctrl+C before running the commands below.

Before continuing, restore the initial value to `0` in `Counter.roc` and
save. The spec below describes that original counter: it starts at `0`,
counts up twice to `2`, then down to `1`. Keeping a different starting
value is valid, but its spec must expect those different counts too.

A spec describes what a user does and sees, located the way a screen reader
would find things:

{{ sample(file="counter/specs/counter.scm", syntax="scheme") }}

```sh
roc signals.roc test
```

```text
Building the app's spec runner...
Running 1 spec:
  passed  the counter counts both ways

The spec passed.
```

`test` builds the app's native spec runner and runs every spec in `specs/`.
The runner drives the real engine and checks the DOM it would build, so a
spec takes milliseconds. A failing spec names its file, line and the step
that did not hold, and `test` exits with 1. The native spec runner is built
for Linux on x86-64, macOS on Apple silicon and on Intel, and Windows on
x86-64, and a spec means the same on each; on any other system (Linux on
ARM64, for now) `test` says which systems run them.
[Testing](@/docs/testing.md) covers the spec language and the Chrome replay.

## Build it for deployment

```sh
roc signals.roc build
```

```text
Built the app into dist/:

  dist/index.html
  dist/assets/5e711d3a91d0f155/app.wasm
  dist/assets/5e711d3a91d0f155/runtime.mjs
  dist/assets/5e711d3a91d0f155/worker.mjs
```

`build` normally makes the app's module with `--opt=size`, lays out `dist/`,
and lists each file it wrote with its size. Some release/compiler pairs
need a compatibility build: for the optimizer failure tracked in
[roc#12976](https://github.com/roc-lang/roc/issues/12976), the tool explicitly
reports that it is using `--opt=dev` instead. That output can be served and
tested, but it is larger and slower; it does not establish optimized
shipping performance. Check the tool's output and the
[current release notes](https://github.com/lukewilliamboswell/roc-signals/releases/latest)
for the mode and limitations of the release you downloaded.

Both modes write the same deployment layout:

- `dist/index.html`, your page, with each quoted relative URL that names
  one of the files below pointed into the hashed directory. Nothing else in
  it changes.
- `dist/assets/<hash>/`: the module, the platform's runtime and worker
  script, and the app's other files (its scripts, styles and images, in
  their own folders). The directory's name is a hash of everything in it, so
  a browser may cache it for ever. The files keep their places relative to
  each other, so the runtime still finds `worker.mjs` beside it.
- Everything under `public/`, copied to the top of `dist/` under its own
  name: put there a file something names by a fixed URL, such as data the
  app's Roc code downloads, `robots.txt` or a favicon.

`build` replaces `dist/` each time. Serve it from any static file server:
`.mjs` files as `text/javascript` and `app.wasm` as `application/wasm`, with
`index.html` not cached. No other headers are needed.

## Working in a checkout

To work on roc-signals itself, or to run this page's counter from
`www/samples/counter/` in a checkout of
[the repository](https://github.com/lukewilliamboswell/roc-signals),
see [Contributing](@/docs/contributing.md): Blueprint provides the tools,
and the platform builds from source.

## Next

Read [Thinking in Signals](@/docs/thinking-in-signals.md) for the model, then
build the [Tutorial](@/docs/tutorial.md) app, which keeps its state in a
store.
