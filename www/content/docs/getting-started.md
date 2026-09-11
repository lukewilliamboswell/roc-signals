+++
title = "Getting Started"
description = "Install the toolchain, build your first app, test it natively, and run it in a browser."
weight = 3
template = "page.html"
+++

# Getting Started

By the end of this page you will have written an app, type-checked it, run an
automated test against it without opening a browser, and seen it running as
WebAssembly.

## What you need

For the checkout workflow on this page:

- **[Roc](https://www.roc-lang.org/install)** — install the exact nightly named
  in `platform-web/main.roc` (the `roc` entry under `packages`).
- **Zig 0.16.0** to build the platform hosts.
- **Python 3** to run the native spec driver.
- **GitHub CLI (`gh`)** authenticated for release operations or optional artifact
  provenance inspection. Building hosts from a checkout and using published
  platform packages do not require it.

Release starters need only their pinned Roc compiler; their platform archives
include the host binaries.

**Only if you want to use the site builder**

- Node.js, [Zola](https://www.getzola.org/), and the
  [Tailwind CSS standalone CLI](https://tailwindcss.com/blog/standalone-cli)
  version 3.4.17 (the site configuration is for Tailwind v3).

## Get the platform

For an app outside this repository, download `signals-starters.zip` from the
[platform releases](https://github.com/lukewilliamboswell/roc-signals/releases).
It contains complete applications, native specs, the matching browser runtime,
and a README with direct Roc build commands. Its application headers name
immutable release URLs; no platform checkout, Zig build, or Python test wrapper
is needed.

The rest of this page uses a checkout so you can edit and test a local example.
Use the clone workflow below and install the nightly named in the `roc` header
in `platform-web/main.roc`. When upgrading an existing app, follow the migration
instructions in the target version's [release
notes](https://github.com/lukewilliamboswell/roc-signals/releases). Changes not
yet released are recorded in the repository's [release notes
directory](https://github.com/lukewilliamboswell/roc-signals/tree/main/releases).

```sh
git clone https://github.com/lukewilliamboswell/roc-signals.git
cd roc-signals
zig build build-test-hosts -Doptimize=ReleaseSmall
```

That last command compiles the Zig host once for every target Roc can link and
drops the results where Roc expects them:

```text
platform-web/targets/arm64mac/libhost.a
platform-web/targets/x64mac/libhost.a
platform-web/targets/arm64musl/libhost.a
platform-web/targets/x64musl/libhost.a
platform-web/targets/wasm32/host.wasm
```

The build downloads the musl `crt1.o` and `libc.a` files from the independently
released dependencies pinned in `dependencies.lock.json`. It verifies their
digests and signed provenance before installing them beside the host outputs.
No compiled libraries are committed. Downloads are cached, and a host change
does not rebuild musl. Verification failures stop the build without substituting
local binaries. See [contributing](@/docs/contributing.md#dependency-artifact-releases)
for dependency release and cache commands.

You only need to re-run it when the Zig host changes. If you skip it, builds
fail with `MISSING TARGET FILE`.

## Your first app

Create the directories, then save the code below as `examples-web/hello/main.roc`:

```sh
mkdir -p examples-web/hello/specs
```

```roc
app [main] { pf: platform "../../platform-web/main.roc" }

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
                    Html.paragraph_s_attrs(label, [Html.test_id("count")]),
                    Html.button("Increment", count.update(|n| n + 1)),
                ],
            )
        },
    )
```

A few details in this example:

- `main : () -> Elem` takes no arguments and `||` is a zero-argument lambda.
  It runs **once**; see [Thinking in Signals](@/docs/thinking-in-signals.md).
- `0.I64` pins the counter's numeric type. A bare `0` would default to `Dec`
  and change its text representation.
- The platform path is relative to your app file. Two directories up from
  `examples-web/hello/` is the repository root.
- `Html.section_c` takes an accessible label (`"Counter"`) as its first
  argument. Labels and roles are not decoration here — they are how tests find
  elements.

Type-check it:

```sh
roc check examples-web/hello/main.roc
```

Resolve any reported errors before building the app. You can run `roc check`
after each edit without rebuilding the host.

## Test it, without a browser

The native build runs specs against a simulated DOM using the same signal
engine as the browser build. It can check state transitions and rendered values.
You still need browser tests for layout, focus, input composition, and browser
integration.

Write `examples-web/hello/specs/increments.scm`:

```lisp
(test "increments"
  (steps
    (expect-visible (role heading :name "Hello from Roc"))
    (expect-text (test-id "count") "Count: 0")
    (click (role button :name "Increment"))
    (expect-text (test-id "count") "Count: 1")))
```

Build and run it. Use the target matching your machine — `arm64mac`, `x64mac`,
`arm64musl`, or `x64musl`. The command below uses Linux x64; replace
`x64musl` for your machine:

```sh
roc build --target=x64musl --output=/tmp/hello examples-web/hello/main.roc
python3 scripts/spec_driver.py /tmp/hello examples-web/hello/specs
```

The driver prints a result for each spec and a pass/fail summary. Exit code `0`
means every assertion passed. A failure includes a diagnostic such as:

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
roc build --target=wasm32 --opt=size --output=/tmp/hello.wasm examples-web/hello/main.roc
```

### Drop it on this site

The [home page](@/_index.md) has a drop zone. Use it with Wasm built against
the platform version that site serves. Drag your `.wasm` file onto it to mount
the app without building the site locally. If you are working from a newer
checkout, serve the matching runtime locally using the instructions below.

### Serve it locally

To run your app as part of the local site, register it in `www/data/examples.toml`:

```toml
[[examples]]
slug = "hello"
title = "Hello"
description = "My first Roc Signals app."
source = "examples-web/hello/main.roc"
specs = "examples-web/hello/specs"
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

Save this as `index.html` in a directory containing `hello.wasm` and the
browser runtime files listed below:

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

Copy `signals.mjs`, `wasm_memory_views.mjs`, and `controlled_input_policy.mjs`
from `www/static/` next to your `.wasm`, preserving their relative paths.
Alternatively, run `python3 scripts/bundle_browser.py` and extract the resulting
`.test-out/signals-browser.zip` there. New releases include this browser archive
alongside the platform bundle. It contains the runtime's imported modules and a
manifest recording the compiler pin and file digests.

Serve these files over HTTP, for example with `python3 -m http.server 8000`
from their directory, then open `http://localhost:8000`. Opening the HTML as a
`file://` URL does not provide the HTTP environment needed to load the module.
The utility classes in the example also need a stylesheet; Signals does not
include CSS automatically. You can use your own styles or the site's generated
`signals.css`.

The runtime must come from the same compatible platform version as the app —
it checks the wire protocol at mount and rejects a mismatch. Keep the files
together when deploying under a GitHub Pages project path; the relative URLs
above work without assuming that your app lives at the domain root.

`mountSignalsApp` also accepts `taskHandler` (to intercept HTTP tasks),
`behaviors` (to attach JavaScript widgets), `telemetry`, and `onError`. See
[Effects, HTTP, and the Browser](@/docs/effects-and-browser.md).

## Where to put your app

Nothing requires your app to live in `examples-web/`. That directory is just where
this repository keeps apps so its test driver can find them. An app can live in any
directory; its `main.roc` header names a local platform path or a released
platform archive.

A typical larger app looks like:

```text
my-app/
  main.roc          # main, shell layout, top-level wiring
  Route.roc        # URL <-> route parsing
  Api.roc          # request builders and JSON decoding
  Home.roc         # page modules
  Article.roc
  Styles.roc       # shared class-name constants
  specs/           # one native test case per .scm file
```

That is Conduit's shape, described in
[Structuring an App](@/docs/app-architecture.md).

## Troubleshooting

**`MISSING TARGET FILE ... host.wasm`**
Run `zig build build-test-hosts -Doptimize=ReleaseSmall`.

**`EFFECTFUL FUNCTION NAME` errors pointing inside the platform** Your Roc
compiler and the platform disagree. Check the compiler pin for your platform
release, or the `roc` header in `platform-web/main.roc` when working from a clone.
Rebuild the app with the matching compiler and deploy its matching browser
runtime.

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

**`Signals wire protocol version mismatch` in the browser** Your `signals.mjs`
and your `.wasm` came from different platform versions. Deploy the matching
browser archive, including all imported modules, from the same release or
checkout used to build the app.

**A successfully compiled Wasm file fails browser validation**
Use `--opt=size` with the pinned Roc compiler. Its dev backend can emit invalid
Wasm for unit-valued state and event callbacks even when compilation succeeds.
The site builder validates every artifact before copying it into a deployment.
The maintained examples have no Linux Wasm skips. See
`UPSTREAM_COMPILER_BUGS.md` in the repository for the reproducer and tested
compiler version; do not assume every build failure has the same cause.

## Next

[Tutorial](@/docs/tutorial.md) builds a real app one concept at a time and ends
with a passing test suite.
