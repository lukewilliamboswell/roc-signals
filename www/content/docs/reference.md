+++
title = "Reference"
description = "The Engine, Files, Html, Layout, Clipboard, Worker, Wire, Port and PortJson APIs at a glance, the platform's limits, and its error classes."
weight = 19
template = "page.html"
+++

# Reference

The [API documentation](../../api/api/) is generated from the platform's source
and documents every public symbol of `Engine`, `Files`, `Html`, `Layout`, `Clipboard`, `Worker`, `Wire`, `Port` and `PortJson`,
including members inherited through public aliases: the authoring API.
Operations only the engine may perform belong to unexposed modules. The engine's storage and executable values are opaque; its implementation
and the interfaces its hosts and test harnesses use live in the platform's
internal `Core` module, which apps cannot import. This page is the map of it. The spec language is in [Testing](@/docs/testing.md).

## Engine

| Area | Symbols | Guide |
|---|---|---|
| Programs | `program`, `program_boot`, `program_store` (an app with a store: `ProgramProps`, `Boot -> Store` and `Boot -> Elem(StoreRoot(_))`), `Program(st)` (the entry names `st` as `Store`), `Program.with_workers`, `Registration` (made by a `Worker` task's or preparation's `registration`), `Program.with_ports`, `PortRegistration`, `Boot`, `boot_storage`, `boot_session`, `boot_media` | [Getting Started](@/docs/getting-started.md) |
| Contexts | `Root`, `StoreRoot(st)` (the top of an app with a store), `In(outer, s)`, `Row(outer, item)`, `Reach(ctx, st)` (how a context reaches the store; a function that uses cells asks `where [ctx.store : () -> Engine.Reach(ctx, _)]`) | [Thinking in Signals](@/docs/thinking-in-signals.md#contexts) |
| Signals | `Signal`, `const`, `Signal.map`, `Signal.map2` (which Roc's record builder calls: `{ a: va, b: vb }.Engine.Signal` is a signal of the record, the way a decision reads several cells), `Signal.lift`, `Signal.lift_row`, text literals/interpolation and `Signal.to_text_signal` | [Thinking in Signals](@/docs/thinking-in-signals.md#signals-declare-what-they-read) |
| The store | `cell`, `table`, `Cells(whole, st, h)` (a description, built with the record builder: `{ a: .., b: .. }.Engine.Cells`; a store of one cell is `Engine.cell(init).map(\|c\| { c: c })`), `Cells.map`, `Cells.map2`, `Cells.with_reset`, `store`, `Stored(tag, st)`, `Store(st, h)`, `Store.cells`, `Store.with_initial`, `Store.after`, `Store.read` | [Shared State](@/docs/shared-state.md) |
| Cells and writes | `Cell(st, a)`, `Cell.signal`, `Cell.state`, `Cell.set`, `Cell.update`, `Write(st)` | [Shared State](@/docs/shared-state.md#writes-are-values) |
| Decisions | `handle`, `handle_by` (handlers generic over the payload), `react`, `react_by` (reactions): each from one pure function that returns a `List(Write(st))`; `does` (a handler from a list of writes, for a transition that needs nothing from the event) | [Shared State](@/docs/shared-state.md#decisions) |
| State | `state`, `State(ctx, s)` (a piece of state as one context sees it, local or shared), `State.signal`, `State.lift`, `State.lift_row` | [Local State, Events, and Forms](@/docs/state-and-events.md) |
| Handlers | `HandlerOf(ctx, p)`, `Handler(ctx)` (text), `FilesHandler(ctx)` (`Received`), `State.update`, `State.update_by`, `State.set_value`, `State.set_value_by`, `HandlerOf.also` (two handlers of one payload as one event), `HandlerOf.lift`, `HandlerOf.lift_row` | [Local State, Events, and Forms](@/docs/state-and-events.md#handlers) |
| Structure | `Elem`, `element`, `text`, `text_s`, `when`, `switch`, `remount_on`, `derive`, `resource`, `Remote(output, error)` (`request`: `Idle`, `Pending`; `answer`: `Unanswered`, `Answered(output)`, `Failed(error)`; `remote.answered()`, the latest answer as `Try(output, [NoAnswer])`), `gather` (one request per input), `Gathered(output, error)` (`jobs`: a `JobState` per input, `Working`, `Answered(output)` or `Failed(error)`; `all`: a `Remote` of the whole list) | [Conditionals and Lists](@/docs/dynamic-structure.md) |
| Lists | `each`, `RowRef`, `RowRef.key`, `RowRef.field`, `RowRef.item` (the whole item), `RowRef.select`, `keyed`, `Keyed` | [Conditionals and Lists](@/docs/dynamic-structure.md#keyed-lists) |
| Table views | `table_view`, `TableViewProps` (`query`, `plan`, `window`), `sort_by` (the sort value's order, then the key's), `QueryPlan(k, v, s)` (the explicit `keep`, `sort`, `compare` form), `Window` (`start`, `count`), `every_row` (the window that draws every row) | [Tables and Table Views](@/docs/tables-and-views.md) |
| Ordered values | `Order.pair`, `Order.asc`, `Order.desc`, `Order.directed`, `Order.utf8`, `Order.compare`; types whose `order_relative_to` also works with ordinary Roc sorting | [Tables and Table Views](@/docs/tables-and-views.md#the-query-is-data) |
| Attributes | `Attr`, `attr`, `attr_s` (present text, including empty), `attr_presence` (a signal of `Absent` or `Present(text)`), `class`, `class_s`, `test_id`, `test_id_s`, `ref`, `ref_s` (a signal of the reference's name, including in a row; the empty name names nothing) | [Attribute values](#attribute-values), [Focus](@/docs/effects-and-browser.md#focus) |
| Events | `on` (bare event type, text payload), `on_with` (text payload and typed `Policy`: `prevent` and `stop`, both false by default), `on_click`, `on_files` (`Change`, `Drop` or `Paste`, files payload), `on_pointer` (`Down`, `Move`, `Up`, `Cancel`, `Pointer` payload), `on_pointer_capture`, `on_pointer_paced`, `on_scroll`, `on_size`, `on_seen` (`SeenProps`), `on_key` (`KeyProps`), `on_document_key` (`DocumentKeyProps`, requires `OutsideRows(ctx)`) | [Local State, Events, and Forms](@/docs/state-and-events.md#handlers) |
| Properties | `Prop(a)`, `Prop.value` (`Str`), `Prop.checked` (`Bool`), `Prop.pointer_zone` (`Str`), `prop`, `prop_s` | [Element properties](#element-properties) |
| Key data | `Key` (`key`, `code`, `ctrl`, `alt`, `shift`, `meta`, `repeat`, `composing`, `heard`), `Chord` (`plain`, `with_ctrl`, `with_alt`, `with_shift`, `with_meta`, `primary`), `Keymap` (`prevent`, `keep`, `every`, `concat`, `outside_text`) | [Keys and shortcuts](@/docs/state-and-events.md#keys-and-shortcuts) |
| Reference commands | `Focus`, `Blur`, `SelectText`, `ApplyValue`, `FocusInPlace`, `ScrollIntoView`, `ScrollTo`; `scroll_into_view`, `ScrollProps` (`block ?? Nearest`, `inline ?? Nearest`, `behavior ?? Auto`), `Align` (`Start`, `Center`, `End`, `Nearest`), `Edge` (`Keep`, `Start`, `End`, `Px(U32)`), `ScrollBehavior` (`Auto`, `Instant`, `Smooth`) | [Focus and scrolling](@/docs/effects-and-browser.md#focus) |
| Time and locale | `Boot.now_ms : I64`, `Boot.seed : U128`, `Boot.languages`, `Boot.zone`; `Zone`, `utc`, `zone_offset : Zone, I64 -> Try(I32, [OutsideZone])`; `Fired(I64)` | [Time, randomness and locale](@/docs/effects-and-browser.md#time-randomness-and-locale) |
| Drafts and clipboard | `SessionStorageGet`, `SessionStorageSet`, `SessionStorageRemove`, `StorageChanges`, `StorageWriteFailures`; `guard_leave : Signal(ctx, Bool) -> Elem(ctx)`; `Clipboard.text`, `Clipboard.html`; `Paste`, `Html.on_paste_text` | [Drafts](@/docs/effects-and-browser.md#drafts-and-other-tabs), [Clipboard](@/docs/effects-and-browser.md#copying-and-pasting-text) |
| Animation | `ViewTransition(List(Str))`, a command in both `Request` and `Command`; marks one complete host-call batch, merges types in issue order, never marks mount | [Animation](@/docs/effects-and-browser.md#animation) |
| Pointer data | `Pointer`: `id`, `kind`, `button`, `buttons`, `modifiers`, `primary`, `at` (`Outside` or `In({ zone, x, y })` with fractions 0–10000) | [Pointer input and dragging](@/docs/state-and-events.md#pointer-input-and-dragging) |
| Files | `File`, `File.name`, `File.size`, `File.mime`, `File.slice`, `File.spans` (the `{ start, len }` ranges of `n` bytes that cover a file, for `read!`), `Received`, `FilesHandler` (the generic handler family at `Received`), `on_files` | [Files](@/docs/files.md) |
| Operations on files | `File.upload` (`UploadProps`: `url`, `method ?? "POST"`, `headers ?? []`, `timeout ?? Unlimited`, `credentials ?? SameOrigin`), `File.sha256`, `File.object_url` (acting where the browser keeps the file), `File.read_bytes`, `File.read_utf8` (reading it into the page; `ReadProps`: `max_bytes ?? 8388608`), `FileError` (`Unreadable`, `TooLarge`, `InvalidUtf8`, `Unavailable`, `Refused`) | [Files](@/docs/files.md) |
| Saving and downloading | `File.save` (a download command; `SaveProps`: `name : [Same, Named(Str)]`), `File.fetch` (`File.FetchProps`: `url`, `method`, `headers`, `timeout : [Unlimited, Ms(U32)]`, `cache ?? Default`, `credentials ?? SameOrigin`), `Fetched`, `FetchFailure`, `FetchError` (for manual status classification) (`Network`, `Timeout`, `Status`, `TooLarge`, `Refused`) | [Files in Tasks](@/docs/files-in-tasks.md) |
| Effects in a worker job | `File.read!` (`{ start, len }`) and `File.contents!`, answering `Try(_, [Unreadable])`, and `File.contents_utf8!`, `Try(Str, [Unreadable, InvalidUtf8])`; `Files.build!` (`import pf.Files`; `BuildProps`: `name`, `mime : [Auto, Mime(Str)] ?? Auto`, `start_from : [Empty, From(File)] ?? Empty`), `Builder`, `Builder.append!` (`Try({}, [TooLarge])`), `Builder.append_file!`, `Builder.finish!` | [Files in Tasks](@/docs/files-in-tasks.md) |
| HTTP | `http`, `HttpProps` (defaulted method, headers, body, timeout, cache and credentials), `Cache` (`Default`, `NoStore`, `Reload`, `NoCache`, `ForceCache`), `Credentials` (`SameOrigin`, `Include`) | [HTTP options](@/docs/effects-and-browser.md#http-options) |
| Transfer progress | `Transfer`, `ProgressReaction`, `ProgressProps`, `State.on_progress`, `react_progress`, `Reaction.with_progress` | [Transfer progress](@/docs/effects-and-browser.md#transfer-progress) |
| Effects | `watch`, `watch_changes`, `watch_latest`, `keep_current`, `on_post`, `on_post_by` (sample a declared reading only when issuing the post), `Outbox(item)` (`outbox({})`, `box.post(item)`, `box.last()`: `Unposted` or `Posted(item)`), `Ask(output, error)`, `Reaction(ctx, issued, result)`, `State.on_result`, `react`, `react_by`, `Reaction.also` (two reactions to one result), `ignore`, `on_cleanup`, `cleanup`, `Request`, `Command` (the requests that await no result, which is what a cleanup's plan returns), `Result` (for deliberate raw plans), `ask_of`, `raw`, `command`, `http`, `http_body`, `HttpError`, `WorkFault`, `FileError`, and the plain data of port requests, `PortMessage`, `PortFailure` and `PortDelivery`, which the typed `Port` module wraps | [Effects and the Browser](@/docs/effects-and-browser.md) |

A component is not an API of its own: it is a type module whose view is
handed the cells it uses ([Components](@/docs/components.md)).

`program_boot` and `program_store` take `ProgramProps`, a record whose
fields default to `storage_keys: []`, `session_keys: []`, `max_inflight: 32`, `media: []` and
`zone_days: 366` (at most 7305 days each side of mount). Pass only the
fields the app needs:

{{ sample(file="program-props.roc", region="program") }}

Boot values an app declares belong in these props; catalogues of request
kinds use `Program.with_workers` and `Program.with_ports`. `Boot` is also a
record with defaults: URL `/`, empty storage, storage available, online
and visible, empty available session storage, with no media pairs, time 0,
seed 0, `["en-US"]` and `utc`.
Pure tests can name only the fields they use:

{{ sample(file="program-props.roc", region="boot") }}

## Table

`Table(k, v)` is the value a table cell holds: rows by a key that has
equality and a hash (`import pf.Engine exposing [Table]`). A decision changes it inside
`cell.update(...)` with these operations, and each names the rows it
touches; see [Tables and Table Views](@/docs/tables-and-views.md).

| Area | Symbols |
|---|---|
| Building | `from_list` (two rows with one key: contract error) |
| Keyed writes | `insert` (a key already present: contract error), `put` (insert or replace), `replace`, `update`, `remove` (each leaves the table unchanged for a key it does not hold) |
| Whole rewrites | `load` (replace every row), `update_all` (change every row) |
| Reading | `get` (a `Try(v, [Missing])`), `contains`, `len`, `fold` and `to_list` (every row with its key; both in no particular order) |
| This turn's changes | `changes` (each written key with its row as it was, or `Rewritten`), `inverse` (the writes that undo this turn's, or `Err(Rewritten)`), `apply` (a list of `Put(k, v)` and `Remove(k)`) |

The changes serve an undo history and tests: in a pure test,
`store.after(writes).read(table).inverse()` tells which rows a transition
wrote.

Table bookkeeping belongs to the internal `TableCore` module and is absent
from `Engine.Table`.

## Html

`Html` is a typed vocabulary over `Engine.element`. Every helper is generic in
its context. Accessible names go in `aria-label`, which the spec locators
match. A helper ending `_s` takes a signal where its plain counterpart
takes a constant; `Html.p_s` takes reactive text, for example.

| Area | Helpers |
|---|---|
| Structure | `div`, `div_s`, `div_attrs`, `section`, `section_s`, `section_attrs`, `h1`, `h2`, `h2_s`, `h3`, `p`, `p_s`, `p_attrs`, `span_s`, `pre_s`, `ul`, `li`, `link`, `label_for` |
| Controls | `button`, `button_s`, `icon_button`, `action_button`, `submit_button`, `text_input`, `number_input`, `textarea`, `checkbox`, `radio`, `select` (`Choices(a)`, `Chose(a)` or `NotOffered`), `form`, `file_input` (`FileInputProps`: `selection : [Single, Multiple] ?? Single`, `accept : [Any, Types(Str)] ?? Any`) |
| Dialogs and popovers | `dialog`, `DialogProps(ctx)` (`open`, `on_close : HandlerOf(ctx, Bool)`, `modal : [Modal, NonModal] ?? Modal`); `popover`, `PopoverProps(ctx)` (`open`, `on_toggle : HandlerOf(ctx, Bool)`, `dismiss : [Auto, Manual] ?? Auto`); both open fields are `Signal(ctx, Bool)` |
| Ordered values | `Order.pair`, `Order.asc`, `Order.desc`, `Order.directed`, `Order.utf8`, `Order.compare`; types whose `order_relative_to` also works with ordinary Roc sorting | [Tables and Table Views](@/docs/tables-and-views.md#the-query-is-data) |
| Attributes | `aria_label`, `aria_label_s`, `aria_describedby`, `aria_invalid`, `disabled`, `flag`, `flag_maybe` |
| Events | `on_input`, `on_change`, `on_focus`, `on_blur`, `on_submit`, `on_cancel`, `on_drop_files`, `on_paste_files`, `on_pointer_down`, `on_pointer_down_capture`, `on_pointer_move`, `on_pointer_move_paced`, `on_pointer_up`, `on_pointer_cancel` |
| Layout reports | `on_scroll`, `on_size`, `on_seen` (`SeenProps`: `ahead : Bool ?? False`) |
| Zones | `zone`, `zone_s` (pointer-zone keys, with empty text marking no zone) |

`section(name, class, children)` names a region for assistive technology
and the spec locators (`aria-label`); it renders no heading, so put one
among the children for a visible title.

Anything else is `Engine.element(tag, attrs, children)`.

## Layout

`import pf.Layout` provides plain report data with no engine dependency:

| Type | Fields |
|---|---|
| `Scroll` | `top : U32`, `left : U32`, rounded CSS pixels from the start edges |
| `Size` | `width : U32`, `height : U32`, content-box CSS pixels |
| `Seen` | `intersecting : Bool`, `ratio_permille : U16`, from 0 to 1000 |

Attach them through `Html.on_scroll`, `on_size` and `on_seen`. Media uses
`ProgramProps.media`, `Boot.media : List((Str, Bool))`,
`boot_media(boot, query) : Try(Bool, [Undeclared])` and the scoped
`MediaChanges(query)` subscription, answered by `Matches(Bool)`.
See [Scrolling and layout](@/docs/effects-and-browser.md#scrolling-and-layout).

## Worker

`Worker` runs registered Roc functions, tasks, in Web Workers; see
[Workers](@/docs/workers.md).

| Area | Symbols |
|---|---|
| Tasks | `task`, `TaskProps(input, output, error)` (`name`, `run! : input => Try(output, error)`, `timeout : [Unlimited, Ms(U32)] ?? Unlimited`, `on_dispose : [Stop, Keep] ?? Stop`, `on_cancel : [Stop, Finish] ?? Stop`), `Task(input, output, error)`, `Task.registration`, `Task.name` |
| Jobs from an effect site | `Task.request`, `Task.result` (a `Try(output, Error(error))`), `Error(error)` (`Failed(error)`, `Timeout`, `Refused`, `Lost(WorkFault)`), `Never` (the error of a task that cannot fail) |
| Resources | `resource`, `resource_when` (for a task or a preparation's task), holding an `Engine.Remote(output, Error(error))`; `gather` (one job per input), holding an `Engine.Gathered(output, Error(error))`; `status`, a resource as one `Status(output, error)`: `Unasked`, `Working`, `Answered(output)`, `Failed(error)`, `Timeout`, `Refused` or `Lost(WorkFault)` |
| Preparations | `preparation`, `PreparationProps(init, state, error)` (`name`, `prepare! : init => Try(state, error)`), `Preparation(init, state, error)`, `Preparation.task`, `PreparedTaskProps(state, input, output, error)` (`name`, `run! : state, input => Try(output, error)`, `timeout`, `on_dispose`, `on_cancel`, as a task's), `Preparation.registration` (given its tasks' registrations), `PreparedTask(init, state, input, output, error)`, `PreparedTask.registration`, `PreparedTask.name`, `PreparedTaskEntry(state)`, `PreparedTask.request`, `PreparedTask.result`, `Question(init, input)` (`init`, `input`) |

## Wire

`Wire` is the binary format of worker payloads. Apps rarely call it: a
task's types decide what is sent.

| Area | Symbols |
|---|---|
| Payloads | `Sendable`, `encode`, `try_encode`, `decode`, `Error` |
| Bulk bytes | `Bytes`, `Bytes.from_list`, `Bytes.to_list` |
| Derivation | `Format`, `State`: the hooks the compiler's codec derivation calls; apps never use them |

## Port

`Port` reaches services the page's JavaScript supplies; see
[Ports](@/docs/ports.md).

| Area | Symbols |
|---|---|
| Declaring | `command` (`CommandProps`: `name`), `call` (`CallProps`: `name`, `timeout : [Unlimited, Ms(U32)] ?? Unlimited`), `subscription` (`SubscriptionProps`: `name`, `delivery`), `Delivery` (`Latest`, `Every(n)`), and each shape's `registration` for `Program.with_ports` |
| From an effect site | `Command.send`, `Call.request`, `Call.result`, `Subscription.subscribe`, `Subscription.message`, `Error` (`Refused`, `Timeout`, `Threw(message)`, `TooLarge`, `Closed`, `Undecodable(why)`) |
| Resources | `resource`, `resource_when` (for a call), holding an `Engine.Remote(output, Error)` |

## PortJson

`PortJson` is the JSON format of port messages, derived from their types,
with bytes and files carried beside the text.

| Area | Symbols |
|---|---|
| Messages | `Sendable`, `encode`, `decode`, `describe`, `Message`, `Error` |
| Derivation | `Format`, `Out`, `State`, `Entries`: the hooks the compiler's codec derivation calls; apps never use them |

## Event payloads

A bubbling event reaches the nearest handler on its target or an ancestor.
An event that does not bubble reaches only a handler on its target. The
browser's `bubbles` flag decides this, so custom event types follow the same
rule. `Engine.on` accepts an open event name; a misspelt name or an event
the element never raises runs no handler. A spec expecting that handler's
result catches it.

The attach function declares a payload kind. Text helpers use the text
kind; `on_files` uses the files kind. The handler's payload type must
match. Policies are a typed record, never suffixes on the name. `prevent`
prevents the default action, and `stop` prevents a bubbling event from
reaching page listeners above the mount. `stop` has no effect on an event
that does not bubble, so its own target can still receive it.

| Text event or files declaration | Payload |
|---|---|
| `click`, `submit` | empty |
| `input` | the control's value |
| `change` | `"true"` or `"false"` for a checkbox or radio, else the value |
| `keydown`, `keyup` | the key |
| `focus`, `blur` | the control's value |
| `change` on a file input, `drop`, `paste`, with `on_files` | the files, as `Received` (see [Files](@/docs/files.md)) |

`Html.checkbox` and `Engine.on_checked` deliver `Bool` on `change` from an
HTML checkbox or radio. `Html.select` delivers `Chose(value)` from its current
offered list, or `NotOffered`. These typed payloads use `HandlerOf(ctx, p)`;
`from_payload_by` converts an incoming payload using a current signal reading.

## Attribute values

`attr` and `attr_s` keep an attribute whose value is empty. Use
`attr_presence(name, signal)` to choose `Absent` or `Present(text)`;
`Present("")` is distinct from absence and both cases prune equal updates
without replacing the element, including in a row template.

Only the boolean attributes `disabled`, `selected`, `readonly`, `required`,
`hidden`, `multiple` and `open` treat `""` and `"false"` as absent; every
other value makes them present. `"true"` is written as an empty attribute;
other present text is kept as given, including `hidden="until-found"`.
`Html.flag_maybe` omits an attribute when false through explicit `Absent`.

{{ sample(file="attributes/main.roc", region="presence") }}

## Element properties

`Engine.prop(row, value)` and `prop_s(row, signal)` set a property from
the closed table below. Their values are typed and equal updates are
pruned, including in a row template. `Html` controls set them for you.

| Row | Value type | Elements | Behavior | Claims attribute |
|---|---|---|---|---|
| `Engine.Prop.value` | `Str` | `input`, `textarea`, `select`, `option` | Live value, guarded while focused or composing; a select settles after option changes | `value` |
| `Engine.Prop.checked` | `Bool` | `input` | Live checked state | `checked` |
| `Engine.Prop.pointer_zone` | `Str` | Any element | Pointer hit-test zone; empty text marks no zone; no attribute mirror | None |

`value` and `checked` mirror their attribute; an empty `value` keeps `value=""`, including
on an option, while false `checked` removes its mirrored attribute.
A claimed name used through an attribute constructor is a contract
error on the row's elements. On another element, such as a custom element
or `<progress>`, `attr("value", ...)` sets only the attribute. A property
on an element its row does not allow, or declared twice, is a contract
error at mount. Applying `value` to a file input is a contract error at
that command, including if its `type` changed through a signal.

Keymaps are private property rows attached only by `on_key` and
`on_document_key`, paired with their handler. They have no public `Prop`
constructor. Both props records require `keymap : Signal(ctx, Keymap)`;
`on` defaults to `Down` and `stop` to false. Key handlers have no static
`prevent` field: the matching keymap entry decides it. `ApplyValue(name)`
is a `Request` and `Command` that applies the last rendered value at a
reference even while focused; it requires a declared `Prop.value` and
waits for composition to end.

The dialog and popover helpers also pair private shown properties with
Boolean native-event echoes. These are not public `Prop` rows or standalone
codecs. Hiding applies in stream order; showing runs after the batch among
commands and effects, with a later hide or removal invalidating an older
queued show. A close/toggle echo settles its paired signal even when its
handler writes nothing. See [Dialogs and popovers](@/docs/state-and-events.md#dialogs-and-popovers)
for lifetimes, ownership restrictions and automatic dismissal.

## Mount options

`mountRocEngineApp({ wasmUrl, root, ...options })` fetches and compiles
`wasmUrl`, mounts the app into the element `root` and returns the runtime.
What an app means is decided in its Roc code and carried on its requests
(a job's timeout, a read's `max_bytes`); a `max…` option is what this
deployment allows, and caps what any request asks for. Every option is
optional.

| Option | Default | What it sets or bounds | Guide |
|---|---|---|---|
| `onFault` | none | Called with the diagnostic when the app breaks a contract and stops | [Getting Started](@/docs/getting-started.md) |
| `viewTransitions` | `"document"` | `"document"` allows marked batches to start document-wide browser view transitions; `"off"` applies directly. Other values refuse mount | [Animation](@/docs/effects-and-browser.md#animation) |
| `maxWorkers` | the core count, at most 8 | Workers alive at once; further jobs wait in order | [Workers](@/docs/workers.md#serving-the-app) |
| `workers` | `"worker"` | `"inline"` runs jobs on the page's thread instead, one at a time | [Workers](@/docs/workers.md#serving-the-app) |
| `workerUrl` | `worker.mjs` beside `runtime.mjs` | Where the worker script is served | [Workers](@/docs/workers.md#serving-the-app) |
| `maxWorkerBytes` | 128 MiB | A worker whose memory has grown past it is ended after its job, its prepared state with it | [Workers](@/docs/workers.md#serving-the-app) |
| `maxOutputBytes` | 256 MiB | Bytes one job may append to its builders; beyond it `append!` answers `TooLarge` | [Files in Tasks](@/docs/files-in-tasks.md#limits) |
| `onWorkerFault` | none | Called with `{ id, task, class, message }` when a job is lost | [Workers](@/docs/workers.md#serving-the-app) |
| `maxFileBytes` | 256 MiB | Bytes one read into the page takes, whatever its `max_bytes`; bytes one digest reads; bytes of one fetched body. Beyond it `FileFailed(TooLarge)`. A job's reads in a worker are not bounded by it | [Files](@/docs/files.md) |
| `ports` | none | The page's handlers, one per port the app declares; a missing or extra one refuses the mount | [Ports](@/docs/ports.md) |
| `maxPortBytes` | 4 MiB (at most 64 MiB) | One port answer or message, JSON text and bytes together; beyond it `TooLarge` | [Ports](@/docs/ports.md) |
| `onPortFault` | none | Called when a command handler or an unsubscribe function fails | [Ports](@/docs/ports.md) |
| `monitor` | `{ history: 128, userTiming: false, payloads: false }` | What the work monitor keeps and reports | [Monitoring Workers](@/docs/worker-monitoring.md) |
| `storage` | the page's `localStorage` | The storage `StorageGet` and `StorageSet` use (an object with `localStorage`'s methods) | [Effects and the Browser](@/docs/effects-and-browser.md) |
| `sessionStorage` | the page's `sessionStorage` | The independent service for declared session keys and session get/set/remove | [Drafts](@/docs/effects-and-browser.md#drafts-and-other-tabs) |
| `maxPasteBytes` | 4 MiB | Nonnegative safe integer; UTF-8 bytes accepted by `Html.on_paste_text`, beyond it `TooLarge`; zero permits only empty text | [Paste text](@/docs/effects-and-browser.md#copying-and-pasting-text) |
| `environment` | browser fact readers | `now()` (safe integer or I64 BigInt), `seed()` (`Uint8Array(16)`), `languages()` and `timeZone(days)` supply boot facts; `now()` also stamps timer and interval callbacks. Optional Boolean `online()` and `visible()` readers at boot and on their events; `visible()` also chooses report drain scheduling. `matchMedia(query)` runs at boot and subscription creation; its object supplies Boolean `matches` and change listener methods, and is retained for that subscription | [Effects and the Browser](@/docs/effects-and-browser.md) |
| `fetch` | the global `fetch` | The function HTTP requests go through, for a page that scripts its own backend | [Effects and the Browser](@/docs/effects-and-browser.md) |
| `manualEffects` | `false` | Requests wait for the caller (`runEffect`); reports wait for `releaseReports()`. Used by the spec runner in Chrome | [Testing](@/docs/testing.md) |
| `manualWork` | `false` | Only worker jobs wait for `runEffect`; every other effect runs on its own; used by the repository's long sessions in Chrome | [Contributing](@/docs/contributing.md#walks-and-soaks) |

An unknown environment key or a non-function refuses mount. A reader that
throws or returns the wrong type refuses mount at boot, or reports an
`executor` fault on a later event. URL reads still use the document's
location; services and deployment limits use their own options.

The browser tests also pass `manualIntervals` (intervals tick only when the
test says), `window` and `document`; an app's page has no reason to set
them.

## Limits

| Resource | Bound | At the bound |
|---|---|---|
| Awaited requests in flight | 32 (`max_inflight`) | The reaction receives `Refused` |
| Follow-up chain depth per event | 64 | Contract error |
| Follow-up turns per event that follow-ups led to (those the event's own turn queued are not counted) | 64 per in-flight slot, at least 4096 | Resource limit |
| HTTP timeout | 600 s | Capped |
| Handlers for one event on one element | 1 | Contract error at mount, or at compile time when the default first page draws it; make one handler of two with `also` |
| Static attributes, children or holes per row template element | 255 | Resource limit |
| Live document-key handlers | 32 per instance; compile-time exclusion under rows | Contract error at mount naming the site |
| Declared media queries | 32 distinct queries of 1–256 UTF-8 bytes | Contract error naming the query |
| Live observations | One per element and kind, structurally bounded by live nodes | Node resource bound; no fixed row-count cap |
| Leave guards | One runtime flag and at most one listener, decided by live sites | No slot or refusal; retained on poison, cleared on unmount/recovery |
| Deferred storage-write failures | Pending recipient occurrences plus ingress entries at most 4096 | `resource_limit`; cancellation drops its pending identities, teardown clears the queue |
| Boot languages | 1–16 strings, at most 64 UTF-8 bytes each | Default reader keeps the first that fit or `en-US`; invalid injected values refuse mount |
| Zone span and offsets | `zone_days` each side (366 by default, at most 7305), 1–128 offsets | Default probe shortens both ends to fit; `OutsideZone` beyond its inclusive span |
| Zone name | 64 UTF-8 bytes | Unavailable or overlong default browser name is empty; invalid injected data refuses mount |
| Live DOM nodes | 2³² − 2 | Resource limit |
| Ingress entries (occurrences and reports) | 4096 | A report drains a full queue early while idle; a waiting transition applies and drains; overflow in other busy phases is a resource limit |
| Transition batches waiting for update | 1 | Inputs queue; a full queue forces application and draining |
| Wait for transition update | 1000 ms | Apply directly and skip the animation |
| Transition observation history | Newest 4096 records and 1 MiB encoded type bytes, absolute U64 count | Overwritten or oversized records fail observation; an oversized record clears prior history. Counter exhaustion disables observation; app execution continues |
| Replaceable reports per source | 1 | A newer report replaces the waiting payload in place |
| Wait for a report's frame | 100 ms | Timer drains a visible page given no frames; hidden pages use a microtask |
| Manual scroll history | Newest 4096 commands, absolute U64 count | Overwritten ordinals and counter exhaustion fail observation; app execution continues |
| Manual native UI callbacks | At most live controlled nodes, one coalesced toggle and a U64 close count per node; 20 s settle wait | Counter exhaustion or timeout fails observation |
| Manual pointer log | 4096 records, taken after each input step | Resource limit on overflow |
| Spec driver pointers | One mouse/pen gesture or up to 16 touches, without overlap between modes | Step error before input; production pointer dispatch has no driver limit |
| Turns delivered before the runtime returns to idle | 4096 | Resource limit; bounds a focus feedback loop even when only one event waits at a time |
| Payload kinds, element properties | Closed tables with one-byte indices | Unknown numbers on the wire are contained as `executor` |
| Event policies | Closed table of 32 bits | Unknown fields do not compile; unknown wire bits are contained as `executor` |
| Live references with one nonempty name | 1, checked at the end of the turn | Contract error naming the name and both construction sites |
| Names in a worker catalogue | 64: tasks, preparations and each preparation's tasks | Contract error at mount |
| Work timeout | 600 s | Capped |
| A cancelled job of a task that says `on_cancel: Finish` | Its timeout, else 600 s after it was asked for | Its worker is ended, its prepared state with it |
| Workers alive at once | `maxWorkers` (default the core count, at most 8) | Jobs wait in order for a free worker |
| Prepared states | One per worker | A new input replaces the least recently used idle worker's |
| A worker's memory | `maxWorkerBytes` (default 128 MiB), checked after each job | The worker is ended after the job, its prepared state with it; the console warns once per preparation whose state was too large to keep |
| Files an app holds at once | 64 | Further files an event carries are not delivered (`Received.refused` counts them); a download with no room is `FileFailed(TooLarge)` |
| Bytes one page read takes | Its `max_bytes` (default 8 MiB), at most `maxFileBytes` (default 256 MiB) | `FileFailed(TooLarge)`, unread |
| Bytes one digest reads | `maxFileBytes` (default 256 MiB) | `FileFailed(TooLarge)`, unread |
| URLs one file gives | 16 ranges, revoked when the file is let go | `FileFailed(TooLarge)` |
| Ports a program declares | 64, names 1 to 128 bytes | Contract error at mount |
| A port's answer or message | `maxPortBytes` (default 4 MiB, at most 64 MiB) | `TooLarge` |
| Replaceable `Latest` report or `Every` backlog per subscription | 1 (`Latest`) or n ≤ 1024 (`Every(n)`) | `Latest` replaces; reports pinned by occurrences count within ingress. `Every` refuses the JavaScript's `emit` |
| Port call timeout | 600 s | Capped |
| Payload nesting | 512 containers | The job is `Lost(Contract)`: an input fails to decode in the worker, an answer is refused there before it is sent |
| Bytes a job appends to its builders | `maxOutputBytes` (default 256 MiB); files appended by reference do not count | `append!` answers `Err(TooLarge)` |
| Files in one job's answer | 16 | The job is `Lost(Contract)`, nothing delivered |
| Room on the page for an answer's files | The page's free slots among its 64 | The job is `Lost(ResourceLimit)`, nothing delivered |
| Room on the page for a port's answer or message with files | The page's free slots among its 64 | `TooLarge`, none of its files kept |
| Files and builders one job holds at once | 64 | The job is `Lost(ResourceLimit)` |
| A fetched body | `maxFileBytes` (default 256 MiB) | `Err(TooLarge)` in the typed fetch result |

## Errors

The engine never repairs invalid input. A broken contract stops the app with
a classified diagnostic naming the rule and, where there is one, the
construction site, for example `contract: duplicate key "r0" in each at site
/3/0`. The runtime keeps the last rendered page, reports the fault through
`onFault`, and refuses further events.

| Class | Cause |
|---|---|
| `contract` | A rule of the API was broken: a duplicate key in an `each`, two live references with one name, a `switch` value outside its cases, a row template that is not a single element, two handlers for one event type on one element, an event type ending in a retired suffix, a property on an element its row does not allow or declared twice, an attribute with a name a property row claims on that element, a value property on a file input, an invalid media catalogue or an undeclared media subscription, a controlled helper with reserved attributes or a `beforetoggle` handler, a text-kind key handler, a 33rd live document-key handler, `ApplyValue` without a declared value property at its reference, a decision whose list replaces a cell an earlier write of the same list wrote, `Table.insert` of a key already present, a table built from two rows with one key, two rows of a plan with its own `compare` that compare `Same`, a view's row read after its key left the table in the same event, an effect feedback loop, an outbox posted twice in one turn, a worker task registered twice or asked for without being registered, a port declared twice or used without being declared or as another shape, a worker effect outside a job, a builder used after `finish!` or after the call that opened it returned, an answer holding more than 16 files, malformed boot or result bytes |
| `resource_limit` | A bound in the table above |
| `out_of_memory` | The Wasm heap could not grow |
| `app_crash` | `crash` in app code, or a Roc runtime error |
| `expect_failed` | A failed `expect` in a development build |
| `executor` | A failure while applying commands, including an external listener preventing a controlled show from reaching its requested state |

`recover()` on the runtime mounts a fresh instance from the same module.

A fault inside a worker job stops only that worker. Its job answers
`WorkLost` with the class (`Lost(fault)` in `Worker.Error`), the diagnostic
goes to the console and `onWorkerFault`, and the page keeps working.
`WorkLost` also reports `unavailable` (the browser has no workers, or a job
running on the page's thread with `workers: "inline"` reached an effect
only a worker has) and `executor` (the worker script itself failed). A
failure the task chose, `Err(error)` from its `run!`, is not a fault: it is
the job's answer, read as `Failed(error)`.

Nothing a port's JavaScript does stops the app. A call whose handler throws,
rejects or answers something that is not JSON data answers `Threw`; a
command handler's failure goes to the console and `onPortFault`. A page
whose `ports` option does not match the app's declarations is refused before
it mounts.

## Protocol

The command stream, event records, boot bytes and program declarations are versioned together. The
current protocol is version 16: every nonempty page batch starts with a flags
byte, and a marked batch ends with `TRANSITION` (opcode 24). Worker answers
have no page-batch header. Session storage adds section 11, and `GUARD` is
opcode 25. Clipboard and failed storage writes have typed results; paste
text has its own payload kind. HTTP carries cache, credentials and an optional
progress interval; transfer reports use tag 26 and counter 47. The full wire protocol is Appendix B of
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).
