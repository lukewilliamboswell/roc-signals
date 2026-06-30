+++
title = "Guide"
weight = 1
template = "page.html"
+++

# Roc Signals Guide

Roc Signals is a Roc platform for building small reactive interfaces that run in
both places this project supports today:

- **the browser**, through the WebAssembly runtime used by this GitHub Pages site;
- **the native test host**, which replays browser-style specs without opening a
  browser.

A Roc app describes its UI as values, signals, and event handlers. The host keeps
that description alive, owns the retained state, runs tasks/timers, and patches
only the parts of the interface that changed.

## The 30-second mental model

Think of a Signals app as a retained reactive graph:

1. Roc runs `main({})` once and returns an `Elem` descriptor tree.
2. That tree contains markup, signal dependencies, event reducers, dynamic-list
   renderers, conditional branches, and effect descriptors.
3. The host builds a graph from the descriptor and renders the initial DOM.
4. When a user event, timer, or task result changes a source signal, the host
   recomputes only the dependent derived signals that can be affected.
5. The host emits DOM patches for changed sinks such as text, input values,
   checked/disabled states, classes, attributes, and mounted subtrees.

The important shift from many UI frameworks is that Roc does **not** rebuild a
whole `view(model)` after every event. You declare the graph once, and the host
keeps it active.

## Your first app

A browser-capable app imports the platform modules and returns an `Elem`:

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : {} -> Elem
main = |_|
    Html.section_c(
        "Hello",
        "grid gap-3 rounded border border-zinc-200 p-4",
        [
            Html.heading_c("Hello from Roc", "text-2xl font-semibold"),
            Html.paragraph("This static UI can run in the browser or native host."),
        ],
    )
```

Examples in this repository use a local platform path. Source files published on
the site are rewritten to point at the downloadable platform bundle for the
current GitHub Pages build.

## Local state and derived values

Use `Ui.state` for state owned by a piece of UI. The state handle gives you:

- `state.signal()` to read the current value as a signal;
- `state.on_str(...)`, `state.on_bool(...)`, and `state.on_unit(...)` to build
  event reducers.

```roc
main : {} -> Elem
main = |_|
    Ui.state(
        "",
        |name| {
            name_signal = name.signal()

            greeting =
                Signal.map(
                    name_signal,
                    |value| if value == "" { "Enter your name" } else { "Hello, ${value}" },
                )

            can_save = Signal.map(name_signal, |value| value != "")
            save_disabled = Signal.map(can_save, |ok| !ok)

            Html.section_c(
                "Profile",
                "grid gap-3",
                [
                    Html.text_input_c(
                        "Name",
                        name_signal,
                        "w-full max-w-md",
                        name.on_str(|_, value| value),
                    ),
                    Html.paragraph_s(greeting),
                    Html.action_button(
                        Signal.const("Save profile"),
                        save_disabled,
                        name.on_unit(|current| current),
                    ),
                ],
            )
        },
    )
```

`Signal.map(name_signal, ...)` declares a dependency. When the user types, the
host updates the `name` source, recomputes `greeting` and `save_disabled`, and
patches only the text/value/disabled sinks that changed.

Use the same pattern for numbers, records, and custom types. Any type used as a
signal value needs an `is_eq` method so the runtime can stop propagation when a
recomputed value is unchanged.

## Events and form controls

The current browser runtime supports the common event/control surface used by
the public examples:

| UI need | Helper |
| --- | --- |
| Static text | `Html.text`, `Html.paragraph`, `Html.heading` |
| Signal-backed text | `Html.text_s`, `Html.paragraph_s` |
| Text input | `Html.text_input`, `Html.text_input_c`, `Html.text_input_attrs` |
| Checkbox | `Html.checkbox`, `Html.checkbox_c`, `Html.checkbox_attrs` |
| Button | `Html.button`, `Html.button_c`, `Html.button_s`, `Html.action_button` |
| Static class/custom attrs | `Html.class_attr`, `Html.attr` |
| Signal-backed class/custom attrs | `Html.class_attr_s`, `Html.attr_s` |
| Click/input/check reducers | `state.on_unit`, `state.on_str`, `state.on_bool` |
| Keyboard payloads | `Html.on_key_down(state.on_key(...))` |
| Submit without navigation | `Html.on_submit_prevent_default(...)` |
| Pointer events | `Html.on_pointer_down`, `on_pointer_up`, `on_pointer_enter`, `on_pointer_leave` |

Keyboard payloads are typed in Roc:

```roc
set_key = |state, payload|
    { ..state, last_key: payload.key, shift_key: payload.shift_key }

Html.text_input_attrs(
    "Search",
    query_signal,
    [
        Html.attr("placeholder", "Type a key"),
        Html.on_key_down(model.on_key(set_key)),
    ],
    model.on_str(|state, value| { ..state, query: value }),
)
```

For submit handlers, use a form helper and attach the static prevent-default
listener policy in the descriptor:

```roc
Html.form_label(
    "Search form",
    [Html.on_submit_prevent_default(model.on_unit(|state| { ..state, submits: state.submits + 1 }))],
    [Html.button("Submit", model.on_unit(|state| state))],
)
```

The JavaScript runtime reads the event payloads it knows how to provide and
passes typed bytes to Roc. App code receives normal Roc values; it does not decode
DOM events by hand.

## Dynamic UI: conditionals and keyed lists

Use `Ui.when` when a region appears/disappears or switches between two subtrees:

```roc
Ui.when(
    is_delivery_step,
    |_| delivery_panel,
    |_| review_panel,
)
```

Each branch is its own scope. When the condition flips, the host disposes the
losing branch, mounts the winning branch, and patches that local subtree.

Use `Ui.each_str` for lists keyed by durable text identity:

```roc
Todo : { id : Str, title : Str, done : Bool }

render_todo : Str, Signal.Signal(Todo) -> Elem
render_todo = |_key, todo| {
    title = Signal.map(todo, |item| item.title)
    done_text =
        Signal.map(
            todo,
            |item| if item.done { "done" } else { "open" },
        )

    Html.section(
        "Todo row",
        [],
        [
            Html.text_s(title),
            Html.text_s(done_text),
        ],
    )
}

todo_list : Signal.Signal(List(Todo)) -> Elem
todo_list = |todos|
    Ui.each_str(todos, |todo| todo.id, render_todo)
```

The key function should return a stable identity such as a database id, slug, or
client-generated id. Do not key by list position. Surviving keys keep their row
scope and any row-local `Ui.state` through reorder/filter operations; removed
keys are disposed.

When a row component needs its own state, put `Ui.state` inside the row renderer:

```roc
render_line : Str, Signal.Signal(Str) -> Elem
render_line = |label, _line| {
    Ui.state(
        1,
        |quantity| {
            quantity_label =
                Signal.map(
                    quantity.signal(),
                    |n| "${label} quantity: ${n.to_str()}",
                )

            Html.section(
                label,
                [],
                [
                    Html.button("Increase ${label}", quantity.on_unit(|n| n + 1)),
                    Html.text_s(quantity_label),
                ],
            )
        },
    )
}
```

The [Checkout Wizard](@/examples/checkout-wizard.md) uses this pattern for cart
line quantities.

## Components and larger apps

A component is just a function that returns an `Elem`. Use `Ui.component` to give
a reusable/stateful piece of UI its own local identity scope:

```roc
counter_component : Str -> Elem
counter_component = |label|
    Ui.component(
        |_|
            Ui.state(
                0,
                |count| {
                    count_label = Signal.map(count.signal(), |n| "${label}: ${n.to_str()}")

                    Html.section(
                        label,
                        [],
                        [
                            Html.button("Increment ${label}", count.on_unit(|n| n + 1)),
                            Html.text_s(count_label),
                        ],
                    )
                },
            ),
    )
```

For larger apps, a practical structure is:

- **Domain modules** define parsed data and business types. They do not contain
  CSS classes or display formatting.
- **View-model modules** turn domain values into presentation records with
  strings and small enums such as `Tone`.
- **Theme modules** map presentation enums to concrete classes.
- **Container functions** own source signals/effects and derive the section
  signals a page needs.
- **Presentational functions** accept one `Signal(Props)` or a focused section
  signal, lower fields with `Signal.map`, and return `Elem`.

A useful convention is: pass one signal of one props record across a component
boundary, then derive leaf fields inside the component. Avoid long parameter
lists of field signals unless there is a specific reason.

The [Ops Dashboard](@/examples/ops-dashboard.md) follows this shape with:

- `Dashboard.roc` for domain parsing/state,
- `DashboardRemote.roc` for per-section remote state,
- `DashboardView.roc` for display records,
- `DashboardTheme.roc` for class mapping,
- `app.roc` for signal wiring and page composition.

## Effects, HTTP, timers, and cleanup

Effects are also descriptors. Roc says what should happen; the host performs the
work and feeds results back into the graph as source updates.

The current app-facing effect helpers are intentionally small:

| Effect need | Helper |
| --- | --- |
| Deterministic fake task for tests/examples | `Signal.fake_task` |
| Task status signal | `Signal.from_task`, `Signal.fold_task` |
| Start a string-request task | `Signal.start_str` |
| Package-aligned HTTP task | `Http.request_task`, `Http.start` |
| Browser HTTP text helper | `Http.get_text_task`, `Http.get_text` |
| Timer source | `Signal.interval(period_ms)` |
| Fire a command when a signal changes | `Ui.on_change(signal, to_cmd)` |
| Fire a command when a scope mounts | `Ui.on_mount(to_cmd)` |
| Cleanup when a scope is disposed | `Ui.on_cleanup(cleanup)` |

`Http.request_task` and `Http.start` use the pinned `roc-lang/http` request and
response types through the platform's `Http` builder/accessor wrappers. The
browser runtime receives an explicit request envelope, executes `fetch`, and
returns an explicit response envelope; JS never reads Roc record layouts. The
`Http.get_text_task` / `Http.get_text` helpers are thin convenience wrappers that
decode response body bytes as UTF-8 text for examples like the dashboard.

For example, `examples/ops-dashboard/app.roc` creates a browser HTTP text task,
starts it on mount, starts it again on interval ticks, and folds the task status
into dashboard state.

A simplified pattern looks like this:

```roc
import pf.Http

main : {} -> Elem
main = |_| {
    task = Http.get_text_task("dashboard")
    status = Signal.fold_task(task, Loading, |body| Ready(body), |err| RequestFailed(err))
    ticks = Signal.interval(2000)

    Html.div_c(
        "grid gap-3",
        [
            Html.text_s(Signal.map(status, status_to_text)),
            Ui.on_mount(|_| Http.get_text(task, "/api/ops/dashboard")),
            Ui.on_change(ticks, |_| Http.get_text(task, "/api/ops/dashboard")),
        ],
    )
}
```

Task identity comes from the owning scope and task source. Disposing a scope
cancels its active intervals/tasks and runs cleanup descriptors.

## How updates reach the browser

At startup, the browser runtime loads the app Wasm module and calls the platform
entrypoint that initializes the UI. The returned descriptor includes retained Roc
closures for reducers, signal transforms, equality checks, dynamic branch/list
builders, and cleanup/effect commands.

After startup, the host does not ask Roc to rebuild the whole app. It calls the
retained closure for the event or source that changed:

- a click calls the reducer built by `state.on_unit`;
- input/check events call reducers built by `state.on_str` or `state.on_bool`;
- task/timer results update their source signals;
- changed derived nodes call the retained `Signal.map`/`Signal.map2`/`combine`
  transforms;
- changed `Ui.when` or `Ui.each_str` sites mount/dispose only the affected
  branch or keyed rows.

The runtime then writes a versioned command buffer for the JavaScript renderer.
Common commands include creating/moving/removing nodes, setting text/value/class
or attributes, setting checked/disabled state, binding/clearing events, starting
or canceling intervals/tasks, and applying dynamic custom attributes/events.

## Performance guidelines

Most good performance falls out of modeling the UI with the right primitive:

- Use signal-backed sinks for values that change without changing structure:
  `Html.text_s`, value-bound inputs (`Html.text_input`), signal-backed classes
  (`Html.class_attr_s`), and signal-backed attrs (`Html.attr_s`).
- Put `Ui.when` around the smallest region whose existence changes.
- Use `Ui.each_str` for dynamic lists and choose stable keys from item identity.
- Put row-local state inside the row renderer so it follows the row key through
  reorder/filter operations.
- Keep derived values derived with `Signal.map`, `Signal.map2`, and
  `Signal.combine` instead of duplicating state.
- Define meaningful `is_eq` for custom signal values; equality is the cutoff that
  prevents unchanged values from waking downstream work.
- Avoid one giant source record feeding one giant view-model if sections can be
  derived independently. Fine-grained signal seams let unrelated panels stay
  quiet.

## Testing apps

The native host runs browser-style specs against semantic locators: roles,
labels, visible text, values, checked/disabled state, and custom attrs. That lets
examples be tested without a browser while still describing user-facing behavior.

A spec looks like:

```txt
expect_visible role:heading name:"Checkout wizard"
fill label:"Email" "team@example.com"
expect_value label:"Email" "team@example.com"
check label:"Accept terms"
expect_checked label:"Accept terms" true
click role:button name:"Place order"
```

Run the representative native suite from the repository root:

```sh
python3 scripts/test.py native --native always
```

Run the broader validation suite with:

```sh
python3 scripts/test.py
```

## Building the GitHub Pages site locally

The static site is the intended front door for the project. To build it and serve
the live WebAssembly examples:

```sh
python3 scripts/serve.py
```

The script builds host artifacts, generates Tailwind CSS, runs Zola, creates the
platform bundle, builds public examples for `wasm32`, copies example source files
under `dist/examples/<slug>/source/`, and starts a local static server.

Useful variants:

```sh
python3 scripts/serve.py --example ops-dashboard --port 9001
python3 scripts/serve.py --app-opt dev
python3 scripts/serve.py --no-server
```

For contributor setup and release-site details, see
[Contributing](@/docs/contributing.md).

## Common mistakes

- **Treating signals as mutable variables.** You do not assign to a signal. Use
  `Ui.state` for source state and reducers for transitions.
- **Rebuilding structure for leaf changes.** If only text, value, checked,
  disabled, class, or an attr changes, use a signal-backed sink rather than a
  larger `Ui.when` branch.
- **Using unstable list keys.** Keys must come from item identity, not from the
  current index.
- **Forgetting row-local state belongs inside the row scope.** If state is outside
  `Ui.each_str`, it is shared by the surrounding scope rather than retained per
  row.
- **Pre-exploding props into many field signals at every boundary.** Prefer one
  `Signal(Props)` and derive fields at the leaves.
- **Mixing domain and presentation concerns.** Keep parsed/domain values free of
  CSS and display strings; convert them in view-model/theme layers.
- **Assuming browser APIs are magically available in Roc.** Browser work happens
  through platform descriptors such as events, tasks, intervals, and render
  commands.

## Where to look next

- Browse the [Examples](@/examples/_index.md) page and open each example's
  **Source** and **Spec** links.
- Read `examples/ops-dashboard/app.roc` for the most complete current browser
  implementation.
- Read `www/static/signals.mjs` if you want to understand the JavaScript runtime
  that applies Wasm command buffers to the DOM.
- Read `design.md` in the repository root for deeper architecture notes.
- Read [Contributing](@/docs/contributing.md) before changing platform APIs,
  host behavior, or site build scripts.
