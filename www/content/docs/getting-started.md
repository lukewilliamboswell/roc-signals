+++
title = "Getting Started"
description = "Install the toolchain, build your first app, test it natively in milliseconds, and run it in a browser."
weight = 3
template = "page.html"
+++

# Getting Started

By the end of this page you will have written an app, type-checked it, run an
automated test against it without opening a browser, and seen it running as
WebAssembly.

## What you need

**Required**

- **[Roc](https://www.roc-lang.org/install)** — a recent nightly. Roc is pre-1.0
  and its syntax still moves; if a code sample here fails to parse, your
  compiler is probably older or newer than this platform expects.
- **[Zig 0.16.0](https://ziglang.org/download/)** — builds the host artifacts
  that Roc links your app against. You do not write any Zig.

**Only if you want to build the full site**

- Python 3, Node.js, [Zola](https://www.getzola.org/), and the
  [Tailwind CSS standalone CLI](https://tailwindcss.com/blog/standalone-cli).

## Get the platform

> **Use a clone, not the published bundle.** Roc app headers can point at a
> released platform archive over HTTPS, and eventually that will be the normal
> way to depend on Roc Signals. Right now the published `0.1` bundle predates
> several breaking Roc syntax changes and **will not compile** with a current
> compiler. Until a refreshed release lands, build against a clone.

```sh
git clone https://github.com/lukewilliamboswell/roc-signals.git
cd roc-signals
zig build build-test-hosts -Doptimize=ReleaseSmall
```

That last command compiles the Zig host once for every target Roc can link and
drops the results where Roc expects them:

```text
platform/targets/arm64mac/libhost.a
platform/targets/x64mac/libhost.a
platform/targets/arm64musl/libhost.a
platform/targets/x64musl/libhost.a
platform/targets/wasm32/host.wasm
```

(The `crt1.o` and `libc.a` files alongside the musl hosts ship in the repo; they
are not build outputs.)

You only need to re-run it when the Zig host changes. If you skip it, builds
fail with `MISSING TARGET FILE`.

## Your first app

Create `examples/hello/app.roc`:

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

main : () -> Elem
main = ||
    Ui.state(
        0.I64,
        |count| {
            label = count.signal().map(|n| "Count: ${n.to_str()}")

            Html.section_c(
                "Counter",
                "grid gap-3",
                [
                    Html.heading_c("Hello from Roc", "text-2xl font-semibold"),
                    Html.paragraph_s(label),
                    Html.button("Increment", count.on_unit(|n| n + 1)),
                ],
            )
        },
    )
```

Three things to notice, since they are unusual if you are new to Roc:

- `main : () -> Elem` takes no arguments and `||` is a zero-argument lambda.
  It runs **once**; see [Thinking in Signals](@/docs/thinking-in-signals.md).
- `0.I64` pins the counter's numeric type. A bare `0` would default to `Dec`
  and render as `"Count: 0.0"` — a real and easy mistake.
- The platform path is relative to your app file. Two directories up from
  `examples/hello/` is the repository root.
- `Html.section_c` takes an accessible label (`"Counter"`) as its first
  argument. Labels and roles are not decoration here — they are how tests find
  elements.

Type-check it:

```sh
roc check examples/hello/app.roc
```

Expect `No errors found in ...`. This takes well under a second and is the loop
you will live in.

## Test it, without a browser

This is the part most worth learning early. Your app compiles to a **native
binary** that runs browser-style specs against a simulated DOM — no browser, no
headless Chrome, no flakiness, and a full run in milliseconds.

Write `examples/hello/spec.txt`:

```txt
expect_visible role:heading name:"Hello from Roc"
expect_text text:"Count: 0" "Count: 0"
click role:button name:"Increment"
expect_text text:"Count: 1" "Count: 1"
```

Build and run it. Use the target matching your machine — `arm64mac`, `x64mac`,
`arm64musl`, or `x64musl`:

```sh
roc build --target=arm64mac --output=/tmp/hello examples/hello/app.roc
/tmp/hello examples/hello/spec.txt
```

Silence and exit code `0` mean every assertion passed. A failure names the line:

```text
TEST FAILED at line 2: locator did not resolve to one element
```

Specs locate elements the way a screen reader or a user would — by role,
accessible name, label, or visible text — so they describe behaviour rather than
DOM structure. They can also resolve tasks, tick timers, and assert work
budgets. See [Testing](@/docs/testing.md).

## Run it in a browser

Your app is the same source either way; only the target changes.

### Build the WebAssembly module

```sh
roc build --target=wasm32 --opt=size --output=/tmp/hello.wasm examples/hello/app.roc
```

A hello-world app lands around 270 KB uncompressed. You can sanity-check that it
mounts, without a browser, using the repository's Node harness:

```sh
node scripts/browser/mount_wasm_example.mjs /tmp/hello.wasm hello --telemetry-summary
```

It prints the command stream the app produced at startup:

```json
{
  "name": "hello",
  "commandBatches": 2,
  "commands": 19,
  "fixedRecordBytes": 456,
  "fixedStringBytes": 47,
  "dynamicBytes": 216,
  "opCounts": {
    "reset_dom": 1, "create_element": 4, "append_child": 4,
    "set_attr_text": 6, "set_text": 3, "bind_click": 1
  }
}
```

Nineteen commands and about 700 bytes to build the whole initial UI. That is the
wire protocol between Roc and JavaScript, and it is all there is.

### Drop it on this site

The [home page](@/_index.md) has a drop zone. Drag your `.wasm` file onto it and
it mounts live in the page. This is the fastest way to see something running and
requires no local site build.

### Serve it locally

To run your app as part of the local site, register it in `www/data/examples.toml`:

```toml
[[examples]]
slug = "hello"
title = "Hello"
description = "My first Roc Signals app."
source = "examples/hello/app.roc"
spec = "examples/hello/spec.txt"
public = true
wasm = true
native = true
bench = false
```

Then build and serve:

```sh
python3 scripts/serve.py --example hello
```

This builds host artifacts, generates CSS, runs Zola, compiles your app to
WebAssembly, and starts a static server. Open the URL it prints.

### Mount it in your own page

The runtime is a plain ES module with no dependencies:

```html
<div id="app"></div>
<script type="module">
  import { mountSignalsApp } from "./signals.mjs";

  const runtime = await mountSignalsApp({
    wasmUrl: "./hello.wasm",
    root: document.getElementById("app"),
  });

  // later: runtime.unmount();
</script>
```

Copy `www/static/signals.mjs` next to your `.wasm`. It must come from the same
platform version — the runtime checks a wire protocol version at mount and
fails immediately on a mismatch rather than misbehaving.

`mountSignalsApp` also accepts `taskHandler` (to intercept HTTP tasks),
`behaviors` (to attach JavaScript widgets), `telemetry`, and `onError`. See
[Effects, HTTP, and the Browser](@/docs/effects-and-browser.md).

## Where to put your app

Nothing requires your app to live in `examples/`. That directory is just where
this repository keeps apps so its test driver can find them. An app is any
directory with an `app.roc` whose header points at `platform/main.roc`.

A typical larger app looks like:

```text
my-app/
  app.roc          # main, shell layout, top-level wiring
  Route.roc        # URL <-> route parsing
  Api.roc          # request builders and JSON decoding
  Home.roc         # page modules
  Article.roc
  Styles.roc       # shared class-name constants
  spec.txt         # native test script
```

That is Conduit's shape, described in
[Structuring a Real App](@/docs/app-architecture.md).

## Troubleshooting

**`MISSING TARGET FILE ... host.wasm`**
Run `zig build build-test-hosts -Doptimize=ReleaseSmall`.

**`EFFECTFUL FUNCTION NAME` errors pointing inside the platform**
Your Roc compiler and the platform disagree. If you are building against the
published `0.1` bundle URL, that is expected — use a clone instead.

**`LITERAL DEFAULTED ... given the default type Dec`**
A bare numeric literal with nothing to pin its type. Annotate the surrounding
value or write `0.U64`. Type your state record explicitly and this stops
happening:

```roc
Model : { count : U64 }

initial : Model
initial = { count: 0 }
```

**`MISSING METHOD ... is_eq`**
An opaque type (`:=`) used as a signal value. Derive equality:

```roc
Tone := [Calm, Warning, Danger].{
    is_eq : _
}
```

**`The map method on Signal has an incompatible type`**
You called `.map` twice on the same binding with different result types.
Annotate the signal you are mapping from:

```roc
state : Signal.Signal(Model)
state = model.signal()
```

This one is common enough that it has its own explanation in
[State, Events, and Forms](@/docs/state-and-events.md#annotate-the-signal-you-map-from).

**`Signals wire protocol version mismatch` in the browser**
Your `signals.mjs` and your `.wasm` came from different platform versions. Copy
`www/static/signals.mjs` from the same clone you built the app with.

**A wasm build segfaults or hangs on Linux**
Known Roc compiler issues, not platform bugs. This repository's own test driver
skips two examples on Linux for exactly this reason — one segfaults building for
`wasm32`, another hangs under `--opt=dev`. If you hit it, try the other
optimization mode, or build on macOS. Check `LINUX_WASM_SKIPS` in
`scripts/serve.py` for the current list.

## Next

[Tutorial](@/docs/tutorial.md) builds a real app one concept at a time and ends
with a passing test suite.
