+++
title = "Reference"
description = "Look up signal, state, rendering, browser, and testing APIs."
weight = 11
template = "page.html"
+++

# Reference

This page summarizes the application APIs and spec commands used in the guides.
For worked examples, follow the topic guides. The public modules under
`platform-web/` provide signatures and module documentation; internal descriptor and
host-value helpers are not application APIs.

For native controls, layouts, virtual lists, and keyboard regions, see
[Native GUI](@/docs/native-gui.md).

The [browser limits](#deliberately-absent) describe capabilities without a
built-in API and where a JavaScript behaviour can help.

## Imports

```roc
import pf.Elem exposing [Elem]
import pf.Browser
import pf.Html
import pf.Http
import pf.Signal
import pf.Rows exposing [Rows]
import pf.Svg
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
| `map` | `Signal(a), (a -> b) -> Signal(b)` | transform one current value |
| `map2` | `Signal(a), Signal(b), (a, b -> c) -> Signal(c)` | two inputs |
| `combine` | `List(Signal(a)) -> Signal(List(a))` | homogeneous list |
| `combine_map` | `List(Signal(a)), (List(a) -> b) -> Signal(b)` | homogeneous inputs projected by one derived node |
| `const` | `a -> Signal(a)` | never changes |
| `select` | `Signal(Str), Str -> Signal(Bool)` | membership in an exact selected key; updates the old and new key members |
| `keyed` | `Signal(Str), value, value -> Signal.Keyed(value)` | shared selected/unselected values for `Ui.Row.select` |
| `interval` | `U64 -> Signal(U64)` | period in milliseconds; tick count starts at 0 |
| `noop` | `Cmd` | a command that does nothing |
| `cleanup` | `Str -> Cleanup` | named cleanup for `Ui.on_cleanup` |

Signal value constructors and transforms require equality for the values they
cache. For example, `map` requires `b.is_eq`; `const` requires `a.is_eq`.
Nominal application types can derive it with `is_eq : _`. See
[State, Events, and Forms](@/docs/state-and-events.md).

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
| `cancel` | `Task(a, err) -> Cmd` |

The public associated types are `Signal.Task(a, err)` and
`Signal.TaskStatus(a, err)`. Low-level task constructors take a `TaskConfig(err)`
record containing `name`, `reset_on_start`, `canceled: () -> err`, and
`refused: () -> err`. The last two initializers declare terminal errors without
requiring the host to interpret application error types.

`TaskStatus(a, err)` is `[Loading, Done(a), Failed(err)]`. Construct tasks with
`Signal.fake_task` or the `Http` helpers. `task_source` and
`task_source_with_eq` are internal platform plumbing, not supported app APIs.

## Native Files

Import `pf.Files` with `platform-gui`. Each task factory takes a diagnostic label;
construct it once in the owning scope and observe it with `Signal.from_task`.
Commands start or supersede work for that declared task.

| Task factory | Start command | Successful value |
| --- | --- | --- |
| `choose_file_task(label)` | `choose_file(task)` | `Choice` |
| `choose_directory_task(label)` | `choose_directory(task)` | `Choice` |
| `choose_save_path_task(label)` | `choose_save_path(task, { directory, suggested_name })` | `Choice` |
| `read_text_task(label)` | `read_text(task, path)` | `{ path, text }` |
| `write_text_task(label)` | `write_text(task, { path, text })` | `{ path, bytes }` |
| `scan_task(label)` | `scan(task, root)` | `{ root, entries }` |
| `list_directory_task(label)` | `list_directory(task, path)` | `{ path, entries }` |
| `open_path_task(label)` | `open_path(task, path)` | `{ path }` |
| `read_preview_task(label)` | `read_preview(task, path)` | `{ path, text, truncated }` |
| `read_log_task(label)` | `read_log(task, { path, position })` | `LogChunk` |

`Choice` is `[Chosen(Str), Canceled]`. The save chooser's `directory` is
`Home` or `At(absolute_path)`. `Home` resolves the native user's home directory;
a missing or non-UTF-8 environment value returns `Unavailable`. Scan entries
have `{ path, kind, bytes }`; kinds are `File`, `Directory`, `SymbolicLink`, and
`Other`. Paths are absolute UTF-8. Byte counts describe regular files.

`list_directory` returns only direct children, with the scan entry and aggregate
path bounds. `read_preview` returns at most 64 KiB of UTF-8 and reports omitted
bytes with `truncated`. Invalid internal text is refused; a code point cut by the
prefix bound is excluded. `open_path` requests the desktop's associated application
through `gio open`; success confirms the launch, not the external application's
lifetime. Cancellation cannot undo a handoff. The external application owns its
subsequent pathname access policy.

`LogPosition` is `Start`, `End`, or `After({ device, inode, offset })` (all `U64`).
`LogChunk` contains `{ path, text, cursor, change, state }`. Each stateless request
returns at most 64 KiB; `LogChange` is `Initial`, `Continued`, `Rotated`, or
`Truncated`, and `LogState` is `More`, `AtEnd`, or `PartialUtf8`. Rotation or an
observed shrink restarts at zero. Incomplete UTF-8 remains unread for retry;
invalid bytes are errors. Applications assemble partial lines and bound history.
`End` seeds EOF after checking its terminal code point, refusing an incomplete
endpoint; skipped history is not validated. Same-inode truncate-and-regrow between
observations cannot be distinguished from continuation.

`Signal.cancel(task)` publishes `Failed(Error.Canceled)` and invalidates late
results. Dismissing a chooser instead produces `Done(Choice.Canceled)`.
`Files.error_text(error)` formats errors for display. Other errors are
`NotFound`, `PermissionDenied`, `InvalidUtf8`, `InvalidPath`, `ResourceLimit`,
`Io`, and `Unavailable`, each with a diagnostic string. Diagnostic text is bounded
at 4,096 UTF-8 bytes and ends with ` [truncated]` when detail was omitted; the error
case remains unchanged. Save suggestions must be single nonempty file names of
at most 255 UTF-8 bytes.

The native host retains at most 16 operations, including canceled workers or
portal dialogs awaiting completion. Saturation returns `ResourceLimit`. Paths
are at most 4,096 bytes; text reads and writes are at most 1 MiB. A scan returns
one complete metadata result of at most 10,000 entries, 64 levels, and 4 MiB of
paths including the root. Concurrent filesystem changes can fail a scan. Symlinks
are reported without traversal. Limits reject the operation
rather than truncating scan/list results. The preview and incremental-log tasks
report their explicit prefix boundaries. Writes replace the destination through a temporary
sibling and rename; cancellation cannot undo an already committed rename.
Replacement is atomic, but parent-directory power-loss durability is not
guaranteed. Failed temporary cleanup returns `Io` and may leave the file behind.

## Ui

| Function | Type | Purpose |
| --- | --- | --- |
| `state` | `a, (State(a) -> Elem) -> Elem` | introduce a source |
| `component` | `(() -> Elem) -> Elem` | private identity scope |
| `when` | `Signal(Bool), (() -> Elem), (() -> Elem) -> Elem` | conditional |
| `switch` | `Signal(case), (case -> Elem) -> Elem` where `case.is_eq` | lazy branch; replace its scope when the case changes |
| `each` | `Signal(Rows(item)), (Ui.Row(item) -> Elem) -> Elem` | keyed rows |
| `action` | `Signal(a), (a -> Cmd) -> Msg` | command for each unit event, using settled declared reads |
| `action_str` | `Signal(a), (a, Str -> Cmd) -> Msg` | command with target text value |
| `action_bool` | `Signal(a), (a, Bool -> Cmd) -> Msg` | command with target checked value |
| `action_key` | `Signal(a), (a, KeyPayload -> Cmd) -> Msg` | command with key text and shift state |
| `action_detail` | `Signal(a), (a, Str -> Cmd) -> Msg` | command with serialized custom-event detail |
| `update_states` | `List(StateWrite) -> Cmd` | replace distinct states in one propagation turn |
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
| `update_cmd` | `State(a), (a -> a) -> Cmd` | transform the destination's settled value when the command executes |
| `write` | `State(a), a -> Ui.StateWrite` | describe one destination of a coordinated write set |

`Ui.KeyPayload` is `{ key : Str, shift_key : Bool }`.

The `_with` methods read both states from the same pre-event snapshot and write
only the receiver. A `set_cmd` emitted by a value-change hook starts a subsequent
state update; several such hooks do not form one atomic multi-source write.
Use `Ui.update_states(List(Ui.StateWrite))` to replace several distinct states
in one propagation turn. Duplicate destinations are errors even if their values
are unchanged. An empty write set does nothing. State commands are reusable:
executing one materializes fresh owned proposals from its captured values.
`state.update_cmd(update)` instead reads its explicitly named destination when
the command executes and applies a pure `update` function to that settled value.
For example, `Ui.on_change(ticks, |_| history.update_cmd(append_event))` updates
retained history without making the timer observer depend on history changes.
The update may run again after preparation refusal, so it must remain pure.

`Ui.action` attaches to a click, submit, or other payload-free event just like a
reducer message. Combine reads with `{ first: first, second: second }.Signal`.
Changing these reads does not run the action; each accepted event does, even
when its reads equal those of the preceding event. Its command can use
`state.set_cmd(value)` to write a state declared in an enclosing scope.

## Rows

`Rows(item)` is an immutable keyed collection. It owns the key projection,
caches exact keys, and retains the transition from its immediate parent generation. Create
one with `Rows.from_list(items, key_of)` or `Rows.empty(key_of)`, then produce a
new generation with `Rows.apply(rows, edits)` or
`Rows.replace_all(rows, items)`. Construction and edits return `Try` so duplicate
keys, missing keys, and invalid ranges are handled before rendering.

Common edits include `Rows.Edit.Append`, `Rows.Edit.InsertAt`,
`Rows.Edit.RemoveKey`, `Rows.Edit.RemoveRange`, `Rows.Edit.SetKey`,
`Rows.Edit.SetAt`, `Rows.Edit.MoveKeyBefore`, `Rows.Edit.MoveRange`, and
`Rows.Edit.Clear`. A batch is applied in order; removing and reinserting a key
within one unpublished batch preserves that row's stable slot.

| Function | Type |
| --- | --- |
| `empty` | `(item -> Str) -> Rows(item)` |
| `from_list` | `List(item), (item -> Str) -> Try(Rows(item), Rows.Error)` |
| `replace_all` | `Rows(item), List(item) -> Try(Rows(item), Rows.Error)` |
| `apply` | `Rows(item), List(Rows.Edit(item)) -> Try(Rows(item), Rows.Error)` |
| `len` | `Rows(item) -> U64` |
| `get` | `Rows(item), U64 -> Try(item, Rows.Error)` |
| `get_key` | `Rows(item), Str -> Try(item, Rows.Error)` |
| `iter` | `Rows(item) -> Iter(item)` |
| `to_list` | `Rows(item) -> List(item)` |
| `is_eq` | `Rows(item), Rows(item) -> Bool` |
| `content_is_eq` | `Rows(item), Rows(item) -> Bool` |

`apply` and `content_is_eq` require `item.is_eq`. `is_eq` compares generation
identity: copies of one generation compare equal; independently constructed
collections can compare unequal even with the same items. Use `content_is_eq`
when you explicitly need content comparison.

`Rows.Error` reports `DuplicateKey`, `IndexOutOfBounds`, `KeyNotFound`,
`RangeOutOfBounds`, or `SlotExhausted`. An invalid edit batch returns an error
without changing the input collection. `MoveRange.to` is an index after removal
of the moved range. `MoveKeyBefore` uses `Rows.Before.Key(key)` or
`Rows.Before.End`; `InsertBefore` is also available for inserting new items.

Removing a row from a committed rendered collection disposes its local state.
Adding the same key in a later update creates a new lifetime. See
[dynamic structure](@/docs/dynamic-structure.md) for examples and ownership rules.

## Html

Suffix conventions: `_c` static class, `_sc` signal class, `_s` signal text or
label, `_attrs` extra attribute list. They all lower to the same descriptors.

### Structure

`div`, `div_c`, `div_sc`, `form`, `form_label`, `section`, `section_c`,
`section_sc`, `link`

### Text

`text`, `text_s`, `heading`, `heading_c`, `paragraph`, `paragraph_c`,
`paragraph_attrs`, `paragraph_s`, `paragraph_s_attrs`, `paragraph_s_c`, `pre_s_c`

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
`Http.HttpError` is `[Network(Str), Timeout, Canceled, ResourceLimit(Str), Unsupported(Str), ResponseMaterialization(Str)]`.

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

## Svg

Import `pf.Svg` for SVG elements that use the same signals, attributes, event
messages, and dynamic scopes as HTML. `Svg.svg(attrs, children)` creates a
viewport; `Svg.group(attrs, children)` groups shapes. `Svg.path`, `Svg.rect`,
`Svg.line`, and `Svg.polyline` accept attribute lists. Use
`Svg.element(local_name, attrs, children)` for other case-sensitive SVG names.
`Svg.text(attrs, label)` and `Svg.text_s(attrs, label_signal)` create genuine SVG
text elements with text-node children.

```roc
Svg.svg([Html.attr("viewBox", "0 0 200 100")], [
    Svg.rect([Html.attr("width", "80"), Html.attr("height", "30")]),
    Svg.text_s([Html.attr("x", "5"), Html.attr("y", "20")], label),
])
```

Namespace selection is explicit, not inherited from parents. Use HTML helpers
for HTML content inside `Svg.element("foreignObject", ...)`. SVG attributes
such as `viewBox` retain their case; use `Html.attr` and `Html.attr_s` for static
and signal-backed values.

## Elem

Usually built through `Html`, but available directly for arbitrary tags:

```roc
Elem.Element({ namespace: Html, tag: "header", attrs: [Html.class_attr("...")], children: [...] })
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

These capabilities have no dedicated Roc API in the current platform. A
JavaScript behaviour can use browser APIs on its attached element and report
events through the declared boundary; it must clean up any resources it starts.

| Not available | Consequence | Workaround |
| --- | --- | --- |
| Programmatic focus | No Roc command for focus-on-error, focus traps, or restoring focus | JS behaviour |
| Scroll control | No scroll-to-top on route change, no scroll restoration | JS behaviour |
| Wall clock / date source | `Signal.interval` counts ticks; it does not report elapsed or calendar time | Supply timestamps through server data or a JS behaviour |
| Clipboard | No copy-to-clipboard | JS behaviour |
| File input / reading file bytes | No built-in file payload extraction; `Http.with_body` can send bytes already available to Roc | JS integration must own file selection and transfer |
| Multi-select | Single-value `select` only | — |
| Modifier keys beyond shift | `Ui.KeyPayload` is `{ key, shift_key }`. No ctrl, meta, or alt, so no Cmd+K | JS behaviour dispatching a `CustomEvent` |
| Portals | Everything mounts inside the root; `document.body` is unreachable | CSS positioning in-tree |
| Document- or window-level events | All event bindings attach to elements | JS behaviour |
| WebSocket / SSE / streaming | No built-in subscription helper | Poll with HTTP, or manage a connection in a JS behaviour |
| Raw HTML injection | By design — no `dangerouslySetInnerHTML` | Parse to `Elem` nodes ([Conduit's `Markdown.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples-web/conduit/Markdown.roc)) |
| List virtualization | `Ui.each` materializes every row | — |
| Table/list element helpers | Use `Elem.Element({ namespace: Html, tag: "table", ... })` directly | — |
| Enter/exit animation hooks | No transition lifecycle | CSS transitions on signal-backed classes |
| Generated unique ids | Applications must keep HTML ids unique across mounted instances | Combine a caller-supplied component prefix with a row key |

### Native locators and timer lifetime

**Custom `role` attributes are invisible to native specs.** `Html.attr("role", "dialog")`
sets a real ARIA attribute in the browser, but the native spec runner only
resolves `role:` locators for roles set by the built-in helpers (`section`,
`form_label`, `link`, `heading`, and the input helpers). Locate anything else by
`test_id:`.

**An interval only runs while a live node depends on it.** Disposing the scope
that consumes a `Signal.interval` cancels the timer. That is the
mechanism behind pause-when-hidden polling, and it is what
`tick-interval-if-active` asserts.

## Build commands

```sh
# Host artifacts (once, and after Zig host changes)
zig build build-test-hosts -Doptimize=ReleaseSmall

# Type-check
roc check examples-web/my-app/main.roc

# Native test binary
roc build --target=arm64mac --output=/tmp/app examples-web/my-app/main.roc
python3 scripts/spec_driver.py /tmp/app examples-web/my-app/specs

# Browser build
roc build --target=wasm32 --opt=size --output=/tmp/app.wasm examples-web/my-app/main.roc

# Inspect the startup command stream
node scripts/browser/mount_wasm_example.mjs /tmp/app.wasm my-app --telemetry-summary

# Local site
python3 scripts/serve.py --example my-app
```

Targets: `arm64mac`, `x64mac`, `arm64musl`, `x64musl`, `wasm32`.
