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

1. Roc runs `main()` once and returns an `Elem` descriptor tree.
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
app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = ||
    Html.section_c(
        "Hello",
        "grid gap-3 rounded border border-zinc-200 p-4",
        [
            Html.heading_c("Hello from Roc", "text-2xl font-semibold"),
            Html.paragraph("This static UI can run in the browser or native host."),
        ],
    )
```

Examples in this repository use the configured release bundle from
`www/config.toml` so they can be built outside a clone of this repository.

## Released and local platform bundles

Pin app sources to a platform bundle URL in the `app` header. That bundle is the
Roc platform API plus the host artifacts Roc needs for native and WebAssembly
targets. Pinning the URL makes examples and app source files buildable outside a
clone of this repository.

For local platform development, build and test against a local bundle instead of
the released URL:

```sh
zig build build-test-hosts -Doptimize=ReleaseSmall
scripts/bundle.sh
python3 scripts/test.py bundle --bundle always --bundle-ref path/to/bundle.tar.zst
```

The repository test driver refuses published release URLs by default so local
tests exercise workspace changes. When you intentionally verify a published
release bundle, pass `--allow-release-platform-url`.

The browser runtime checks the WebAssembly app before mounting. If the generated
wasm and `www/static/signals.mjs` disagree about the Signals wire protocol
version or required protocol features, mounting fails immediately with a
`Signals wire protocol version mismatch` or
`Signals wire protocol feature mismatch` error. Use a matching platform bundle
and runtime file when deploying.

## Local state and derived values

Use `Ui.state` for state owned by a piece of UI. The state handle gives you:

- `state.signal()` to read the current value as a signal;
- `state.on_str(...)`, `state.on_bool(...)`, and `state.on_unit(...)` to build
  event reducers.

```roc
main : () -> Elem
main = ||
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

When a derived value needs several named signals, prefer Roc's record-builder
syntax instead of looking for `Signal.map3` or `Signal.map4`:

```roc
profile =
    {
        first: first_name.signal(),
        last: last_name.signal(),
        active: active.signal(),
    }.Signal

summary =
    Signal.map(profile, |value| {
        status = if value.active { "active" } else { "paused" }
        "${value.first} ${value.last}: ${status}"
    })
```

Use the same pattern for numbers, records, and custom types. Any type used as a
signal value needs an `is_eq` method so the runtime can stop propagation when a
recomputed value is unchanged.

## Events and form controls

The current browser runtime supports the common event/control surface used by
the public examples:

| UI need | Helper |
| --- | --- |
| Structure and links | `Html.div`, `Html.section`, `Html.form`, `Html.form_label`, `Html.link` |
| Static text | `Html.text`, `Html.paragraph`, `Html.heading` |
| Signal-backed text | `Html.text_s`, `Html.paragraph_s`, `Html.pre_s_c` |
| Text input | `Html.text_input`, `Html.text_input_c`, `Html.text_input_attrs` |
| Number input draft | `Html.number_input`, `Html.number_input_c`, `Html.number_input_attrs` |
| Textarea | `Html.textarea`, `Html.textarea_c`, `Html.textarea_attrs` |
| Single-value select | `Html.select`, `Html.select_c`, `Html.select_attrs`, `Html.option`, `Html.option_attrs` |
| String-valued radio group | `Html.radio`, `Html.radio_c`, `Html.radio_attrs` |
| Checkbox | `Html.checkbox`, `Html.checkbox_c`, `Html.checkbox_attrs` |
| Button | `Html.button`, `Html.button_c`, `Html.button_s`, `Html.button_s_c`, `Html.button_attrs`, `Html.button_s_attrs`, `Html.action_button`, `Html.action_button_c`, `Html.action_button_attrs` |
| Static class/custom/test attrs | `Html.class_attr`, `Html.attr`, `Html.test_id` |
| Signal-backed class/custom attrs | `Html.class_attr_s`, `Html.attr_s` |
| Optional signal-backed attrs | `Html.attr_maybe_s`, `Html.aria_activedescendant_s` |
| Boolean and ARIA attrs | `Html.bool_attr`, `Html.bool_attr_if`, `Html.bool_attr_s`, `Html.required`, `Html.readonly`, `Html.aria_describedby`, `Html.aria_invalid_s` |
| JS behavior marker | `Html.behavior(name)` |
| Click/input/check reducers | `state.on_unit`, `state.on_str`, `state.on_bool` |
| Keyboard payloads | `Html.on_key_down(state.on_key(...))` |
| Custom event detail payloads | `Html.on_custom(name, state.on_detail(...))` |
| Submit without navigation | `Html.on_submit_prevent_default(...)` |
| Pointer events | `Html.on_pointer_down`, `Html.on_pointer_up`, `Html.on_pointer_enter`, `Html.on_pointer_leave` |
| Focus/change/composition events | `Html.on_focus`, `Html.on_blur`, `Html.on_change`, `Html.on_composition_start`, `Html.on_composition_end` |
| Named events with static policy | `Html.on_event(name, Html.event_policy_..., msg)` |
| Named events with default policy | `Html.on_custom(name, msg)` |
| Named events with explicit delivery | `Html.on_event_delivery(name, policy, Html.event_delivery_native, msg)` |

Many element helpers also expose suffix variants such as `_c`, `_sc`, `_s`,
and `_attrs` for static classes, signal-backed classes or text, and extra
attributes. Public examples use these variants heavily; they lower to the same
descriptor vocabulary as the base helpers.

Keyboard payloads are typed in Roc as `Ui.KeyPayload`
(`{ key : Str, shift_key : Bool }`):

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

Custom events can carry text through `event.detail`:

```roc
Html.div(
    [
        Html.test_id("traffic-chart"),
        Html.on_custom("chart-select", model.on_detail(|state, value| { ..state, selected_point: value })),
    ],
    [Html.text("Traffic chart")],
)
```

Number inputs keep the browser draft as text while editing. Store the draft
string on `input`, then parse it on a commit event such as blur:

```roc
Html.number_input_attrs(
    "Seats",
    seats_draft_signal,
    [Html.on_blur(model.on_unit(commit_seats_draft))],
    model.on_str(set_seats_draft),
)
```

Single-value selects use the same string reducer path. The select's
signal-backed value is the canonical selected option value, and `change` delivers
the browser target value:

```roc
Html.select(
    "Plan",
    plan_signal,
    [
        Html.option("starter", "Starter"),
        Html.option("growth", "Growth"),
    ],
    model.on_str(set_plan),
)
```

Textareas use the same controlled text contract as text inputs:

```roc
Html.textarea(
    "Message",
    message_signal,
    model.on_str(set_message),
)
```

Radio groups are string-valued. Each `Html.radio` option derives its checked
state from the shared selected-value signal and dispatches its option value on
`change`:

```roc
Html.radio("Monthly", "billing", "monthly", billing_signal, model.on_str(set_billing))
Html.radio("Annual", "billing", "annual", billing_signal, model.on_str(set_billing))
```

For submit handlers, use a form helper and attach the static prevent-default
listener policy in the descriptor. Buttons with their own independent click
handler should set `type="button"` inside a form so the browser does not also
run the submit default action. A button that should submit the form can use
`type="submit"` or omit `type` and rely on the form's submit handler:

```roc
Html.form_label(
    "Search form",
    [Html.on_submit_prevent_default(model.on_unit(|state| { ..state, submits: state.submits + 1 }))],
    [
        Html.button_attrs(
            "Save draft",
            [Html.attr("type", "button")],
            model.on_unit(|state| { ..state, drafts: state.drafts + 1 }),
        ),
    ],
)
```

A production validation pattern keeps validation as derived signals, points
`aria-describedby` at app-rendered messages, and starts async submit work by
changing a request signal. This is app-authored validation; browser constraint
validation integration is not part of the shipped form surface.

```roc
can_submit = |state| (!Str.is_empty(state.email)) and state.accepted

submit_if_valid = |state| {
    if can_submit(state) {
        next_count = state.submit_count + 1
        request = "${state.email}#${next_count.to_str()}"
        { ..state, attempted: True, submit_count: next_count, submit_request: request }
    } else {
        { ..state, attempted: True }
    }
}

email_invalid = Signal.map(form.signal(), |state| state.attempted and Str.is_empty(state.email))
email_message = Signal.map(form.signal(), |state|
    if state.attempted and Str.is_empty(state.email) {
        "Email validation: enter an email address."
    } else {
        "Email validation: ready."
    },
)

task = Signal.fake_task("form-submit", |value| value, |err| err)
request = Signal.map(form.signal(), |state| state.submit_request)
task_loading = Signal.fold_task(task, True, |_| False, |_| False)
submit_state =
    {
        form: form.signal(),
        loading: task_loading,
    }.Signal
submit_disabled = Signal.map(submit_state, |value|
    (!can_submit(value.form)) or ((value.form.submit_count > 0) and value.loading),
)

Html.form_label(
    "Validation form",
    [Html.on_submit_prevent_default(form.on_unit(submit_if_valid))],
    [
        Html.text_input_attrs(
            "Invite email",
            Signal.map(form.signal(), |state| state.email),
            [
                Html.aria_describedby("invite-email-message"),
                Html.aria_invalid_s(email_invalid),
            ],
            form.on_str(|state, value| { ..state, email: value }),
        ),
        Html.div([Html.attr("id", "invite-email-message")], [Html.text_s(email_message)]),
        Html.action_button_attrs(
            Signal.const("Send invite"),
            submit_disabled,
            [Html.attr("type", "button")],
            form.on_unit(submit_if_valid),
        ),
        Ui.on_change(request, |payload| Signal.start_str(task, payload)),
    ],
)
```

The internal `form-validation-pattern` fixture locks the same pattern with a
native spec: invalid submit marks fields, valid submit starts a task, the button
is disabled while invalid or pending, and task resolution updates the status.

Use `Html.attr_maybe_s` when a signal-backed custom text attribute needs true
absence instead of an empty-string sentinel. `None` removes the attribute;
`Some(value)` sets it. For active-descendant widgets, use the focused sugar:

```roc
active_descendant = Signal.map(menu.signal(), |state|
    if state.open {
        Some("option-alpha")
    } else {
        None
    },
)

Html.text_input_attrs(
    "Assignee",
    query,
    [Html.aria_activedescendant_s(active_descendant)],
    form.on_str(update_query),
)
```

For less common event names, use `Html.on_event` with typed static policy data.
Use `Html.on_event_delivery` only when the binding must explicitly request
`Html.event_delivery_native`; `Html.on_event` and `Html.on_custom` use
`Html.event_delivery_auto`. For example, a nested button can stop pointer
events from reaching a parent drag handler without adding a one-off helper:

```roc
open_menu = |state| { ..state, menu_open: True }
stop_drag = model.on_unit(|state| state)

Html.button_attrs(
    "Open menu",
    [
        Html.on_event("pointerdown", Html.event_policy_stop_propagation, stop_drag),
        Html.on_event("pointerup", Html.event_policy_stop_propagation, stop_drag),
    ],
    model.on_unit(open_menu),
)
```

Common policies are available as constants such as
`Html.event_policy_none`, `Html.event_policy_prevent_default`,
`Html.event_policy_stop_propagation`, and
`Html.event_policy_stop_immediate`. For rarer combinations, use the public
`Html.EventPolicy` record shape rather than adding helper families:

```roc
self_capture = { ..Html.event_policy_none, capture: True, self: True }
Html.on_event("click", self_capture, model.on_unit(select_self_only))
```

The JavaScript runtime reads the event payloads it knows how to provide and
passes typed bytes to Roc. App code receives normal Roc values; it does not decode
DOM events by hand.

Use `Html.behavior(name)` for browser-only widgets registered through
`mountSignalsApp({ behaviors })`. The runtime attaches and cleans up the matching
behavior within that mount, and calls behavior `update` only for dynamic custom
attributes such as `Html.attr_s` and `Html.attr_maybe_s`. A behavior is not a
general JS-to-Roc message channel or subscription source; app-visible values
should still enter through declared event handlers such as `Html.on_custom`.

## Rich content without raw HTML

Render rich text as ordinary `Elem` nodes. A markdown parser can map headings,
lists, blockquotes, code spans, emphasis, and links to `Elem.Element` trees, with
all user-controlled copy placed in `Html.text` or `Html.text_s` leaves. Do not
inject raw HTML into the browser runtime.

`examples/markdown-editor/main.roc` shows the current pattern: the editor stores a
small markdown subset, the app parses that text into block/inline records, and
the preview renders those records with `Ui.each_str`, `Elem.Element`, and
signal-backed text. Link safety is an app concern; the example allowlists
`https://`, `http://`, `/`, `#`, and `mailto:` links and renders unsafe links as
plain text.

## Dynamic UI: conditionals and keyed lists

Use `Ui.when` when a region appears/disappears or switches between two subtrees:

```roc
Ui.when(
    is_delivery_step,
    || delivery_panel,
    || review_panel,
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

The [Data Grid](@/examples/data-grid.md) uses this pattern for inline cell
editing across a windowed row list.

## Components and larger apps

A component is just a function that returns an `Elem`. Use `Ui.component` to give
a reusable/stateful piece of UI its own local identity scope:

```roc
counter_component : Str -> Elem
counter_component = |label|
    Ui.component(
        || Ui.state(
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

The [Package Explorer](@/examples/package-explorer.md) follows this shape with:

- `Dashboard.roc` for domain parsing/state,
- `DashboardRemote.roc` for per-section remote state,
- `DashboardView.roc` for display records,
- `DashboardTheme.roc` for class mapping,
- `main.roc` for signal wiring and page composition.

## Effects, HTTP, timers, and cleanup

Effects are also descriptors. Roc says what should happen; the host performs the
work and feeds results back into the graph as source updates.

The current app-facing effect helpers are intentionally small:

| Effect need | Helper |
| --- | --- |
| Deterministic fake task for tests/examples | `Signal.fake_task` |
| Task status signal | `Signal.from_task`, `Signal.fold_task` |
| Start a string-request task | `Signal.start_str` |
| Package-aligned HTTP task | `Http.request_task`, `Http.start`, `Http.get` |
| Browser HTTP text helper | `Http.get_text_task`, `Http.get_text` |
| HTTP request builders/accessors | `Http.method_*`, `Http.request_from_method`, `Http.with_*`, `Http.add_header`, `Http.request_*` |
| HTTP response/error helpers | `Http.response_*`, `Http.response_status`, `Http.response_headers`, `Http.response_body`, `Http.error_text` |
| Timer source | `Signal.interval(period_ms)` |
| Current browser location | `Browser.location()` |
| Browser navigation commands | `Browser.push_state`, `Browser.replace_state` |
| Browser document title command | `Browser.set_title` |
| Page visibility source | `Browser.visibility()` |
| Browser online status | `Browser.online()` |
| Browser storage reads | `Browser.local_storage_text`, `Browser.session_storage_text` |
| Browser storage writes/removals | `Browser.set_local_storage_text`, `Browser.set_session_storage_text`, `Browser.remove_local_storage`, `Browser.remove_session_storage` |
| Fire a command when a signal changes | `Ui.on_change(signal, to_cmd)` |
| Fire a command for the first mounted value and later changes | `Ui.on_change_initial(signal, to_cmd)` |
| Fire a command when a scope mounts | `Ui.on_mount(to_cmd)` |
| Cleanup when a scope is disposed | `Signal.cleanup`, `Ui.on_cleanup(cleanup)` |

`Http.request_task` and `Http.start` use the pinned `roc-lang/http` request and
response types through the platform's method, builder, and accessor wrappers.
The browser runtime receives an explicit request envelope, executes `fetch`, and
returns an explicit response envelope; JS never reads Roc record layouts. The
`Http.get` is a thin full-response `GET` wrapper. `Http.get_text_task` /
`Http.get_text` decode response body bytes as UTF-8 text for examples like the
dashboard; they are not a general JSON or body codec layer.

Browser HTTP policy is intentionally narrow today. The runtime passes method,
headers, body, timeout, and an abort signal to `fetch`; it does not set
`credentials`, `redirect`, `mode`, `cache`, or referrer policy. That means the
browser defaults apply: same-origin credentials, followed redirects, and normal
CORS enforcement. HTTP statuses, including 4xx and 5xx responses, resolve as
responses. Request and response envelopes preserve headers as ordered pairs,
including duplicate names. Helper lookups return the first case-insensitive match.
For real browser `fetch` responses, the runtime relays whatever
`response.headers.entries()` exposes, so browser normalization still applies. A
CORS denial, DNS failure, blocked request, or other rejected `fetch` is reported
to Roc as `Http.Network(message)`. Runtime timeouts report `Http.Timeout`, and
scope disposal or replacement of an in-flight task reports `Http.Canceled`.

For example, `examples/package-explorer/main.roc` creates a task per panel,
starts it on mount, starts it again on interval ticks, and folds the task status
into dashboard state, including nested service-detail JSON used by its routed
drill-down view. It also derives route state from `Browser.location()`, intercepts
navigation links with the static `prevent_default` event policy, and emits
`Browser.push_state` / `Browser.replace_state` commands through `Ui.on_change`.
It derives document titles from the active route and emits `Browser.set_title`
through `Ui.on_change_initial` so deep links set the first browser title. The
same app uses `Browser.visibility()` to pause polling while the tab is hidden.
`examples/field-notes/main.roc` uses `Browser.online()` to hold captured notes in
an outbox while offline and drain them when the browser returns online.
`examples/pomodoro-tracker/main.roc` declares localStorage text keys at mount, folds
`Browser.StorageText` into draft state, writes edits through storage commands,
and removes all draft keys when the user clears the saved order.

`Browser.location()` is deliberately raw: `path` includes its leading `/`, while
`query` and `hash` omit `?` and `#`. Route parsing, key namespacing, storage
serialization, and domain validation stay in app/package code. Storage reads
return `Browser.StorageText`: `StorageMissing`, `StorageValue(text)`, or
`StorageUnavailable(message)`. Storage writes and removals are commands today;
failed write/remove commands report as host/runtime errors rather than
app-visible command results.

A simplified pattern looks like this:

```roc
import pf.Http

main : () -> Elem
main = || {
    task = Http.get_text_task("dashboard")
    status = Signal.fold_task(task, Loading, |body| Ready(body), |err| RequestFailed(err))
    ticks = Signal.interval(2000)

    Html.div_c(
        "grid gap-3",
        [
            Html.text_s(Signal.map(status, status_to_text)),
            Ui.on_mount(|| Http.get_text(task, "/api/ops/dashboard")),
            Ui.on_change(ticks, |_| Http.get_text(task, "/api/ops/dashboard")),
        ],
    )
}
```

Task identity comes from the owning scope and task source. Disposing a scope
cancels its active intervals/tasks and runs cleanup descriptors.
Browser environment sources use the same owner-scoped model: the runtime seeds
location, visibility, online, and declared storage reads before the first render,
then cleans up browser listeners and active resources when the owning scope or
mount is disposed.
Browser commands such as navigation, document title updates, and storage writes
stay explicit effects, so apps decide when state changes should touch browser
globals.

## How updates reach the browser

At startup, the browser runtime loads the app Wasm module and calls the platform
entrypoint that initializes the UI. The returned descriptor includes retained Roc
closures for reducers, signal transforms, equality checks, dynamic branch/list
builders, and cleanup/effect commands.

One active browser mount owns one Wasm instance today. `mountSignalsApp` creates
a fresh instance for each mount, and the wasm host keeps its engine state
module-global inside that instance. If a page needs multiple independent roots,
instantiate the app once per root; do not share one `WebAssembly.Instance` across
simultaneous roots. Calling `unmount()` disposes scopes, tasks, intervals,
behaviors, event listeners, and DOM ids for that runtime.

After startup, the host does not ask Roc to rebuild the whole app. It calls the
retained closure for the event or source that changed:

- a click calls the reducer built by `state.on_unit`;
- input/check events call reducers built by `state.on_str` or `state.on_bool`;
- task/timer results update their source signals;
- browser location, visibility, online, and declared storage sources update from
  host-owned environment payloads;
- changed derived nodes call the retained `Signal.map`/`Signal.map2`/`combine`
  transforms;
- changed `Ui.when` or `Ui.each_str` sites mount/dispose only the affected
  branch or keyed rows.

The runtime then writes a versioned command buffer for the JavaScript renderer.
Common commands include creating/moving/removing nodes, setting text/value/class
or attributes, setting checked/disabled state, binding/clearing events, starting
or canceling intervals/tasks, and applying dynamic custom attributes/events.
When browser telemetry is enabled, `commands` entries report fixed-record,
fixed-string, and dynamic-buffer byte counts; `commands_applied.decode` reports
the fixed and dynamic decode counts/bytes used while applying that batch.

When browser telemetry is enabled, task lifecycle entries include `start_task`,
`task_resolution` with `failed` for rejected task results, `cancel_task` when an
active request is aborted by replacement or disposal, and
`ignored_task_resolution` / `unknown_task_resolution` for late or invalid task
settlements.

## Performance guidelines

Most good performance falls out of modeling the UI with the right primitive:

- Use signal-backed sinks for values that change without changing structure:
  `Html.text_s`, value-bound inputs (`Html.text_input`), signal-backed classes
  (`Html.class_attr_s`), and signal-backed attrs (`Html.attr_s`,
  `Html.attr_maybe_s`).
- Put `Ui.when` around the smallest region whose existence changes.
- Use `Ui.each_str` for dynamic lists and choose stable keys from item identity.
- Put row-local state inside the row renderer so it follows the row key through
  reorder/filter operations.
- Keep derived values derived with `Signal.map`, record builders such as
  `{ first: first_signal, last: last_signal }.Signal`, and `Signal.combine`
  instead of duplicating state.
- Define meaningful `is_eq` for custom signal values; equality is the cutoff that
  prevents unchanged values from waking downstream work.
- Avoid one giant source record feeding one giant view-model if sections can be
  derived independently. Fine-grained signal seams let unrelated panels stay
  quiet.

## Testing apps

The native host runs browser-style specs against semantic locators: roles,
labels, visible text, values, checked/disabled state, and custom attrs. That lets
examples be tested without a browser while still describing user-facing behavior.
Use native specs for app semantics and work budgets; keep browser-only details,
such as exact IME event ordering or CSS layout, in browser contract tests.

A spec is one data-only S-expression test case. Files use the `*.scm` suffix so
editors recognize the Scheme syntax, and live in an app's `specs/`
directory:

```lisp
(test "checkout succeeds"
  (steps
    (expect-visible (role heading :name "Team Checkout"))
    (expect-attr (role region :name "Cart") data-panel "cart")
    (fill (label "Email") "team@example.com")
    (expect-value (label "Email") "team@example.com")
    (check (label "Accept terms"))
    (expect-checked (label "Accept terms") true)
    (click (role button :name "Place order"))
    (expect-text (text "Receipt sent: 1") "Receipt sent: 1")))
```

The directory driver discovers cases recursively, sorts their relative paths,
and runs each in a fresh process. It supports bounded parallelism, glob filters,
deterministic `CURRENT/TOTAL` sharding, per-case timeouts, and fail-fast
scheduling through `scripts/test.py` or the standalone `scripts/spec_driver.py`.

Locators are semantic:

| Locator | Example |
| --- | --- |
| Role and accessible name | `(role button :name "Send invite")` |
| Associated label | `(label "Invite email")` |
| Exact visible text | `(text "Submit status: idle")` |
| Test id | `(test-id "chart")` |

Action commands model the event surface the native host supports:

```lisp
(click (role button :name "Save"))
(real-click (role button :name "Open note"))
(pointer-down (role region :name "Release card"))
(pointer-up (role region :name "Release card"))
(pointer-enter (role region :name "Drop target"))
(pointer-leave (role region :name "Drop target"))
(key-down (label "Command search") "Enter" false)
(focus (label "Message"))
(fill (label "Message") "draft")
(composition-start (label "Message"))
(composition-end (label "Message"))
(blur (label "Message"))
(change (label "Plan") "growth")
(select-option (label "Plan") "enterprise")
(submit (role form :name "Signup form"))
(check (label "Accept terms"))
(uncheck (label "Accept terms"))
(custom-event (test-id "traffic-chart") "chart-select" "point-1")
```

`custom_event` sends its final string argument as `event.detail`; handlers built
with `State.on_detail` receive that text.

`click` dispatches a direct click binding on the target. `real_click` dispatches
`pointerdown -> pointerup -> click` through the propagation path, including
capture/bubble, `self`, and stop policy, so it is the right command for nested
controls inside draggable or clickable parents. For submit buttons inside forms,
`real_click` also runs the form submit default action unless click policy
prevents default. Omitted button `type` behaves as submit, while `type="button"`
stays click-only. Reset buttons dispatch app-managed prevent-default `reset`
bindings. Checkbox controls use the checked-change default path even without a
click handler. `submit` is for app-managed forms and requires a unit submit
binding from `Html.on_submit_prevent_default`.

Assertions cover visible semantics and host state:

```lisp
(expect-visible (role heading :name "Form Validation Pattern"))
(expect-absent (role region :name "Queue Widget"))
(expect-text (text "Submit status: sending") "Submit status: sending")
(expect-value (label "Invite email") "ops@example.com")
(expect-attr (label "Invite email") aria-invalid "")
(expect-no-attr (label "Invite email") aria-invalid)
(expect-checked (label "Accept terms") true)
(expect-disabled (role button :name "Send invite") true)
(expect-updates (label "Message") 2)
```

Task, interval, and cleanup commands make async workflows deterministic:

```lisp
(expect-pending-task "form-submit" 1)
(resolve-task "form-submit" "queued")
(reject-task "lookup" "offline")
(resolve-stale-task "lookup" "late")
(expect-canceled-task "lookup" 1)
(tick-interval 1000)
(tick-interval-if-active 1000)
(expect-interval 1000 1)
(expect-cleanup "live search panel cleanup" 1)
```

Metric assertions let specs lock scaling budgets around a specific action. Call
`mark-metrics` before the action, then assert exact or maximum deltas:

```lisp
(mark-metrics)
(click (role button :name "Reverse rows"))
(expect-metric-delta rows_reused 4)
(expect-metric-delta-at-most stream_nodes_scanned 4096)
(expect-metric-delta signal_record_table_rebuilt 0)
```

Pick the metric that answers the question you are asking:

- **Did derived work stay proportional to the change?** `derived_calls_into_roc`
  counts one call per `map` / `map2` / `combine` transform actually evaluated.
  This is the fine-grained budget: it should scale with the size of the change,
  not the size of the graph.
- **Did an equality cutoff stop propagation?** `propagation_prunes` counts each
  derived node that recomputed to an equal value and therefore did not
  propagate.
- **Did the reconciler reuse rows?** `rows_reused`, `rows_created`,
  `rows_removed`, `scopes_created`, `scopes_disposed`. These are semantic —
  assert them exactly.
- **How much reached the DOM?** `set_text`, `set_value`, `set_checked` count the
  writes that actually landed, and are the honest answer for a keyed-list app.
  `patches_emitted` also carries per-row reconciler bookkeeping — in an
  `each_str`-heavy view it can run several times `set_text` even when every row
  is reused — so treat it as an upper bound, not a measure of DOM writes.
  Bound all of them with `expect_metric_delta_at_most`; their exact values shift
  with unrelated engine changes, and creating a row emits one patch per static
  attribute, so adding a `test_id` moves them.

`dirty_source_roots` counts the sources a change dirtied — one per event
dispatch, or the number of host source signals a location, visibility, online,
or storage change touched. It is 1 for almost every user interaction regardless
of graph depth, so it is a sanity check that a change entered at one place, not
a work budget.

`examples/_fixtures/metric-semantics/` demonstrates the difference: one click on
a source feeding a four-deep chain plus one always-equal node reports
`dirty_source_roots 1`, `derived_calls_into_roc 6`, `propagation_prunes 1`,
and `patches_emitted 1`.

Other metric names include `stream_nodes_scanned`,
`stream_nodes_scanned_events`, `render_indexes_refreshed`,
`active_intervals_synced`, `active_graph_records_rebuilt`,
`signal_record_table_rebuilt`, `stale_task_results_ignored`,
`retained_alloc_delta`, `host_retained_alloc_delta`, and
`host_retained_bytes_delta`. The authoritative
metric list lives in `src/spec/spec_runner.zig`.

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
python3 scripts/serve.py --example package-explorer --port 9001
python3 scripts/serve.py --app-opt dev
python3 scripts/serve.py --no-server
```

For the browser host + public apps build gate, run both Roc optimization modes
without starting a server. Run these commands sequentially because both write
`dist/`:

```sh
python3 scripts/serve.py --no-server --app-opt dev
python3 scripts/serve.py --no-server --app-opt size
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
- Read `examples/package-explorer/main.roc` for routing and independent async
  panels, and `examples/conduit/` for the largest end-to-end application.
- Read `www/static/signals.mjs` if you want to understand the JavaScript runtime
  that applies Wasm command buffers to the DOM.
- Read `design.md` in the repository root for deeper architecture notes.
- Read [Contributing](@/docs/contributing.md) before changing platform APIs,
  host behavior, or site build scripts.
