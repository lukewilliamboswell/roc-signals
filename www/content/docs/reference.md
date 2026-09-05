+++
title = "Reference"
description = "The complete API surface — signals, state, elements, effects, browser sources, and the spec language."
weight = 11
template = "page.html"
+++

# Reference

The complete public surface. For explanations, follow the links into the guide
pages; this page is for looking things up.

Anything not listed here is not part of the supported surface. The platform is
intentionally small:
if you need something outside this surface, it is app code or a JavaScript
[behaviour](@/docs/effects-and-browser.md#javascript-widgets). The
[Deliberately absent](#deliberately-absent) section at the end lists the gaps
people actually hit, so you can find them before you hit them.

## Imports

```roc
import pf.Elem exposing [Elem]
import pf.Browser
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui
```

An app's entrypoint is always:

```roc
main : () -> Elem
main = || ...
```

## Signal

`Signal.Signal(a)` — an opaque typed signal. Methods can be called
receiver-style (`signal.map(f)`), which is the idiomatic form.

| Function | Type | Notes |
| --- | --- | --- |
| `map` | `Signal(a), (a -> b) -> Signal(b)` | derived node; the edge |
| `map2` | `Signal(a), Signal(b), (a, b -> c) -> Signal(c)` | two inputs |
| `combine` | `List(Signal(a)) -> Signal(List(a))` | homogeneous list |
| `combine_map` | `List(Signal(a)), (List(a) -> b) -> Signal(b)` | homogeneous inputs projected by one derived node |
| `const` | `a -> Signal(a)` | never changes |
| `interval` | `U64 -> Signal(U64)` | ticks from 0 while mounted |
| `noop` | `Cmd` | a command that does nothing |
| `cleanup` | `Str -> Cleanup` | named cleanup for `Ui.on_cleanup` |

For three or more inputs use the record builder rather than nesting `map2`:

```roc
{ price: price, qty: qty, tax: tax }.Signal
```

### Tasks

| Function | Type |
| --- | --- |
| `fake_task` | `Str, (Str -> a), (Str -> err) -> Task(a, err)` |
| `from_task` | `Task(a, err) -> Signal(TaskStatus(a, err))` |
| `fold_task` | `Task(a, err), b, (a -> b), (err -> b) -> Signal(b)` |
| `start_str` | `Task(a, err), Str -> Cmd` |

`TaskStatus(a, err)` is `[Loading, Done(a), Failed(err)]`. Construct tasks with
`Signal.fake_task` or the `Http` helpers. `task_source` and
`task_source_with_eq` are internal platform plumbing, not supported app APIs.

## Ui

| Function | Type | Purpose |
| --- | --- | --- |
| `state` | `a, (State(a) -> Elem) -> Elem` | introduce a source |
| `component` | `(() -> Elem) -> Elem` | private identity scope |
| `when` | `Signal(Bool), (() -> Elem), (() -> Elem) -> Elem` | conditional |
| `switch` | `Signal(case), (case -> Elem) -> Elem` where `case.is_eq` | lazy branch; replace its scope when the case changes |
| `each` | `Signal(Rows(item)), (Ui.Row(item) -> Elem) -> Elem` | keyed rows |
| `on_mount` | `(() -> Cmd) -> Elem` | run on scope mount |
| `on_change` | `Signal(a), (a -> Cmd) -> Elem` | run on value change |
| `on_change_initial` | `Signal(a), (a -> Cmd) -> Elem` | first value **and** changes |
| `on_cleanup` | `Cleanup -> Elem` | run on scope disposal |

### `Ui.Row(a)`

| Method | Type | Purpose |
| --- | --- | --- |
| `key` | `Row(a) -> Str` | exact UTF-8 row identity |
| `signal` | `Row(a) -> Signal(a)` | stable live item source |
| `map` | `Row(a), (a -> value) -> Signal(value)` where `value.is_eq` | ordinary equality-pruned projection |
| `select` | `Row(a), Signal.Keyed(value) -> Signal(value)` | fused exact-key selected/unselected value |

Keys are compared as exact UTF-8 bytes without normalization or case folding.
`Row.map` is ordinary graph `Signal.map`; it does not introduce a separate row
observer or snapshot lifecycle.

Build a shared keyed selector once with
`selected_key.keyed(when_selected, otherwise)`, then call `row.select(keyed)`.
Each row remains an ordinary graph record, while the typed selector operations
are retained once by the keyed construction site.

## Rows

`Rows(item)` is an immutable keyed collection. It owns the key projection,
caches exact keys, and carries generation lineage plus stable row slots. Create
one with `Rows.from_list(items, key_of)` or `Rows.empty(key_of)`, then produce a
new generation with `Rows.apply(rows, edits)` or
`Rows.replace_all(rows, items)`. Construction and edits return `Try` so duplicate
keys, missing keys, and invalid ranges are handled before rendering.

Common edits include `Rows.Edit.Append`, `Rows.Edit.InsertAt`,
`Rows.Edit.RemoveKey`, `Rows.Edit.RemoveRange`, `Rows.Edit.SetKey`,
`Rows.Edit.SetAt`, `Rows.Edit.MoveKeyBefore`, `Rows.Edit.MoveRange`, and
`Rows.Edit.Clear`. A batch is applied in order; removing and reinserting a key
within one unpublished batch preserves that row's stable slot.

### `Ui.State(a)`

| Method | Type | Fires on |
| --- | --- | --- |
| `signal` | `State(a) -> Signal(a)` | — |
| `on_unit` | `State(a), (a -> a) -> Msg` | click, submit, blur |
| `on_str` | `State(a), (a, Str -> a) -> Msg` | input / change value |
| `on_bool` | `State(a), (a, Bool -> a) -> Msg` | checkbox change |
| `on_key` | `State(a), (a, KeyPayload -> a) -> Msg` | keydown |
| `on_detail` | `State(a), (a, Str -> a) -> Msg` | custom event detail |
| `on_unit_with` | `State(a), State(b), (a, b -> a) -> Msg` | snapshot a second state while reducing the first |
| `on_str_with` | `State(a), State(b), (a, b, Str -> a) -> Msg` | text input plus a second state |
| `on_bool_with` | `State(a), State(b), (a, b, Bool -> a) -> Msg` | checkbox plus a second state |
| `on_key_with` | `State(a), State(b), (a, b, KeyPayload -> a) -> Msg` | keyboard plus a second state |
| `on_detail_with` | `State(a), State(b), (a, b, Str -> a) -> Msg` | custom event plus a second state |
| `set_cmd` | `State(a), a -> Cmd` | describe a replacement from a command-producing hook |

`Ui.KeyPayload` is `{ key : Str, shift_key : Bool }`.

The `_with` methods read both states from the same pre-event snapshot and write
only the receiver. A `set_cmd` emitted by a value-change hook starts a subsequent
state update; several such hooks do not form one atomic multi-source write.

## Html

Suffix conventions: `_c` static class, `_sc` signal class, `_s` signal text or
label, `_attrs` extra attribute list. They all lower to the same descriptors.

### Structure

`div`, `div_c`, `div_sc`, `form`, `form_label`, `section`, `section_c`,
`section_sc`, `link`

### Text

`text`, `text_s`, `heading`, `heading_c`, `paragraph`, `paragraph_c`,
`paragraph_attrs`, `paragraph_s`, `paragraph_s_c`, `pre_s_c`

### Controls

| Control | Helpers |
| --- | --- |
| Text input | `text_input`, `text_input_c`, `text_input_attrs` |
| Number input | `number_input`, `number_input_c`, `number_input_attrs` |
| Textarea | `textarea`, `textarea_c`, `textarea_attrs` |
| Select | `select`, `select_c`, `select_attrs`, `option`, `option_attrs` |
| Radio | `radio`, `radio_c`, `radio_attrs` |
| Checkbox | `checkbox`, `checkbox_c`, `checkbox_attrs` |
| Button | `button`, `button_c`, `button_attrs` |
| Signal-label button | `button_s`, `button_s_c`, `button_s_attrs` |
| Label + disabled button | `action_button`, `action_button_c`, `action_button_attrs` |

Single-select only. No multi-select and no file input.

### Attributes

| Helper | Purpose |
| --- | --- |
| `class_attr`, `class_attr_s` | static / signal class |
| `attr`, `attr_s` | static / signal named attribute |
| `attr_maybe_s` | signal attribute where `None` removes it |
| `bool_attr`, `bool_attr_if`, `bool_attr_s` | boolean attributes |
| `required`, `readonly` | common static booleans |
| `aria_label`, `aria_describedby`, `aria_invalid_s`, `aria_activedescendant_s` | ARIA |
| `test_id` | test/locator hook |
| `behavior` | mark for a JavaScript behaviour |

### Events

| Helper | Event |
| --- | --- |
| `on_pointer_down` / `_up` / `_enter` / `_leave` | pointer events |
| `on_focus`, `on_blur`, `on_change` | focus and change |
| `on_key_down` | keydown, with `KeyPayload` |
| `on_composition_start`, `on_composition_end` | IME |
| `on_submit_prevent_default` | submit without navigation |
| `on_custom(name, msg)` | named event, default policy |
| `on_event(name, policy, msg)` | named event, explicit policy |
| `on_event_delivery(name, policy, delivery, msg)` | explicit delivery |

Policies: `event_policy_none`, `event_policy_prevent_default`,
`event_policy_stop_propagation`, `event_policy_stop_immediate`. Build custom
combinations from the record:

```roc
{ ..Html.event_policy_none, capture: True, self: True }
```

Delivery: `event_delivery_auto` (default), `event_delivery_native`.

## Http

`Http.Header` is `{ name : Str, value : Str }`.
`Http.HttpError` is `[Network(Str), Timeout, Canceled, Unsupported(Str), ResponseMaterialization(Str)]`.

| Group | Members |
| --- | --- |
| Tasks | `request_task(purpose)`, `get_text_task(purpose)` |
| Start | `start(task, request)`, `get(task, uri)`, `get_text(task, uri)` |
| Methods | `method_get`, `method_post`, `method_put`, `method_delete`, `method_patch`, `method_unknown(name)` |
| Build request | `request_from_method`, `with_method`, `with_uri`, `with_body`, `with_headers`, `add_header`, `with_timeout_ms`, `with_no_timeout` |
| Read request | `request_method`, `request_method_str`, `request_uri`, `request_headers`, `request_body`, `request_timeout` |
| Read response | `response_status`, `response_headers`, `response_body` |
| Build response | `response_from_status`, `response_with_status`, `response_with_headers`, `response_add_header`, `response_with_body` |
| Errors | `error_text(err)` |
| Header tuples | `header_to_tuple`, `header_from_tuple` |

A task created with `request_task("feed")` registers under the spec name
`http:send:feed`.

Non-2xx statuses resolve as **responses**, not errors. The runtime does not set
`credentials`, `redirect`, `mode`, `cache`, or referrer policy.

## Browser

| Type | Definition |
| --- | --- |
| `Location` | `{ path : Str, query : Str, hash : Str }` |
| `Visibility` | `[Visible, Hidden]` |
| `StorageText` | `[StorageMissing, StorageValue(Str), StorageUnavailable(Str)]` |

`path` keeps its leading `/`; `query` and `hash` omit `?` and `#`.

| Sources | Type |
| --- | --- |
| `entropy_seed()` | `Signal(U32)` |
| `location()` | `Signal(Location)` |
| `visibility()` | `Signal(Visibility)` |
| `online()` | `Signal(Bool)` |
| `local_storage_text(key)` | `Signal(StorageText)` |
| `session_storage_text(key)` | `Signal(StorageText)` |

| Commands | Type |
| --- | --- |
| `push_state(location)` | `Location -> Cmd` |
| `replace_state(location)` | `Location -> Cmd` |
| `set_title(title)` | `Str -> Cmd` |
| `set_local_storage_text(key, value)` | `Str, Str -> Cmd` |
| `set_session_storage_text(key, value)` | `Str, Str -> Cmd` |
| `remove_local_storage(key)` | `Str -> Cmd` |
| `remove_session_storage(key)` | `Str -> Cmd` |

## Elem

Usually built through `Html`, but available directly for arbitrary tags:

```roc
Elem.Element({ tag: "header", attrs: [Html.class_attr("...")], children: [...] })
```

Variants: `Element`, `Text`, `TextSignal`, `State`, `When`, `Each`, `Component`,
`OnChange`, `OnChangeInitial`, `OnMount`, `Cleanup`.

There is no raw-HTML variant. All user-controlled text goes through `Html.text`
or `Html.text_s`.

## Spec language

Run a `specs/` directory with `scripts/spec_driver.py`. Each `.scm` file wraps
one case as `(test "name" (steps ...))`. See [Testing](@/docs/testing.md).

### Locators

`(role <role> :name "<name>")` · `(label "<label>")` ·
`(text "<exact text>")` · `(test-id "<id>")`

### Actions

```lisp
(click <locator>)                 (real-click <locator>)
(fill <locator> "<text>")        (change <locator> "<value>")
(check <locator>)                 (uncheck <locator>)
(select-option <locator> "<value>")
(submit <locator>)                (focus <locator>)  (blur <locator>)
(key-down <locator> "<key>" true|false)
(pointer-down <locator>)          (pointer-up <locator>)
(pointer-enter <locator>)         (pointer-leave <locator>)
(composition-start <locator>)     (composition-end <locator>)
(custom-event <locator> "<event-name>" "<detail>")
```

### Assertions

```lisp
(expect-visible <locator>)
(expect-absent <locator>)
(expect-text <locator> "<text>")
(expect-value <locator> "<text>")
(expect-attr <locator> <attr-name> "<value>")
(expect-no-attr <locator> <attr-name>)
(expect-checked <locator> true|false)
(expect-disabled <locator> true|false)
(expect-updates <locator> <count>)
```

### Async and lifecycle

```lisp
(resolve-task "<name>" "<payload>")
(resolve-stale-task "<name>" "<payload>")
(reject-task "<name>" "<payload>")
(expect-pending-task "<name>" <count>)
(expect-canceled-task "<name>" <count>)
(tick-interval <period-ms>)
(tick-interval-if-active <period-ms>)
(expect-interval <period-ms> <count>)
(expect-cleanup "<name>" <count>)
```

### Browser environment

```lisp
(setup
  (initial-location "<path>")
  (initial-visibility visible|hidden)
  (initial-online online|offline)
  (local-storage "<key>" "<value>")
  (session-storage "<key>" "<value>"))

(navigate "<path>")
(history-back)  (history-forward)
(set-visibility visible|hidden)  (set-online online|offline)
(expect-current-location "<path>")
(expect-document-title "<title>")
(expect-local-storage "<key>" "<value>")
(expect-no-local-storage "<key>")
(expect-session-storage "<key>" "<value>")
(expect-no-session-storage "<key>")
```

Forms inside `(setup ...)` apply **before** the first render.

### Work budgets

```lisp
(mark-metrics)
(expect-metric-delta <metric> <delta>)
(expect-metric-delta-at-most <metric> <delta>)
```

Common metrics: `derived_calls_into_roc`, `rows_created`,
`rows_removed`, `rows_reused`, `scopes_created`, `scopes_disposed`,
`events_processed`, `propagation_prunes`, `stale_task_results_ignored`,
`active_intervals_synced`, `render_indexes_refreshed`,
`active_graph_records_rebuilt`, `signal_record_table_rebuilt`,
`stream_nodes_scanned`, `stream_nodes_scanned_events`, `retained_alloc_delta`,
`host_retained_alloc_delta`, `host_retained_bytes_delta`.

`patches_emitted` is available but deliberately unused: see the testing notes in
the contributing guide for why patch counts are watched through the benchmarks
rather than pinned in a spec.

The authoritative list is in `src/spec/spec_runner.zig`.

## JavaScript runtime

```js
import { mountSignalsApp } from "./signals.mjs";

const runtime = await mountSignalsApp({
  wasmUrl,        // required
  root,           // required: a DOM element
  taskHandler,    // optional: intercept HTTP tasks
  behaviors,      // optional: { name: { attach(el, ctx) -> cleanup, update(el, attrName, ctx) } }
  telemetry,      // optional: runtime event callback
  onError,        // optional
});

runtime.unmount();
```

Also exported: `instantiateSignalsWasm`, `instantiateSignalsBytes`,
`createHttpTaskRouter`, `httpJsonResponse`, `httpTextResponse`,
`httpTaskError`, `httpHeaderValue`.

One WebAssembly instance per mount.

## Deliberately absent

Things that do not exist today. Each is a real limit, not an oversight in this
page — check here before designing around one.

| Not available | Consequence | Workaround |
| --- | --- | --- |
| Programmatic focus | No focus trap, no autofocus, no focus-on-error, no focus restore after a modal | JS behaviour |
| Scroll control | No scroll-to-top on route change, no scroll restoration | JS behaviour |
| Wall clock / date source | No "3 minutes ago", no "expires today". `Signal.interval` counts ticks, not time | Server timestamps, or a JS behaviour |
| Clipboard | No copy-to-clipboard | JS behaviour |
| File input / reading file bytes | No uploads originating in Roc (`Http.with_body` can send bytes, nothing can produce them from disk) | JS behaviour or `taskHandler` |
| Multi-select | Single-value `select` only | — |
| Modifier keys beyond shift | `Ui.KeyPayload` is `{ key, shift_key }`. No ctrl, meta, or alt, so no Cmd+K | JS behaviour dispatching a `CustomEvent` |
| SVG | The runtime uses `createElement`, not `createElementNS`; `tag: "svg"` yields an unknown element | JS behaviour |
| Portals | Everything mounts inside the root; `document.body` is unreachable | CSS positioning in-tree |
| Document- or window-level events | All event bindings attach to elements | JS behaviour |
| WebSocket / SSE / streaming | Realtime is polling only | `taskHandler`, or poll |
| Raw HTML injection | By design — no `dangerouslySetInnerHTML` | Parse to `Elem` nodes ([Conduit's `Markdown.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples/conduit/Markdown.roc)) |
| List virtualization | `Ui.each` materializes every row | — |
| Table/list element helpers | Use `Elem.Element({ tag: "table", ... })` directly | — |
| Enter/exit animation hooks | No transition lifecycle | CSS transitions on signal-backed classes |
| Generated unique ids | `aria-describedby` targets are hand-written, so repeated rows collide | Derive an id from the row key |

Two subtleties worth knowing:

**Custom `role` attributes are invisible to native specs.** `Html.attr("role", "dialog")`
sets a real ARIA attribute in the browser, but the native spec runner only
resolves `role:` locators for roles set by the built-in helpers (`section`,
`form_label`, `link`, `heading`, and the input helpers). Locate anything else by
`test_id:`.

**An interval only runs while a live node depends on it.** Disposing the scope
that consumes a `Signal.interval` genuinely cancels the timer. That is the
mechanism behind pause-when-hidden polling, and it is what
`tick-interval-if-active` asserts.

## Build commands

```sh
# Host artifacts (once, and after Zig host changes)
zig build build-test-hosts -Doptimize=ReleaseSmall

# Type-check
roc check examples/my-app/main.roc

# Native test binary
roc build --target=arm64mac --output=/tmp/app examples/my-app/main.roc
python3 scripts/spec_driver.py /tmp/app examples/my-app/specs

# Browser build
roc build --target=wasm32 --opt=size --output=/tmp/app.wasm examples/my-app/main.roc

# Inspect the startup command stream
node scripts/browser/mount_wasm_example.mjs /tmp/app.wasm my-app --telemetry-summary

# Local site
python3 scripts/serve.py --example my-app
```

Targets: `arm64mac`, `x64mac`, `arm64musl`, `x64musl`, `wasm32`.
