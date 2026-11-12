+++
title = "Reference"
description = "The Engine, Table, Html, Worker, Wire, Port and PortJson APIs at a glance, the platform's limits, and its error classes."
weight = 18
template = "page.html"
+++

# Reference

The [API documentation](../../api/api/) is generated from the platform's source
and documents every public symbol of `Engine`, `Table`, `Html`, `Worker`, `Wire`, `Port` and `PortJson`:
the authoring API, and nothing else. Every `Engine` type is opaque; the engine's implementation
and the interfaces its hosts and test harnesses use live in the platform's
internal `Core` module, which apps cannot import. This page is the map of it. The spec language is in [Testing](@/docs/testing.md).

## Engine

| Area | Symbols | Guide |
|---|---|---|
| Programs | `program`, `program_boot`, `program_store` (an app with a store: the configuration, `Boot -> Store` and `Boot -> Elem(StoreRoot(_))`), `Program`, `Program.with_workers`, `Registration` (made by a `Worker` task's or preparation's `registration`), `Program.with_ports`, `PortRegistration`, `Boot`, `boot_storage` | [Getting Started](@/docs/getting-started.md) |
| Contexts | `Root`, `StoreRoot(st)` (the top of an app with a store), `In(outer, s)`, `Row(outer, item)`, `Reach(ctx, st)` (how a context reaches the store; a function that uses cells asks `where [ctx.store : () -> Engine.Reach(ctx, _)]`) | [Thinking in Signals](@/docs/thinking-in-signals.md#contexts) |
| Signals | `Signal`, `const`, `Signal.map`, `Signal.map2` (which Roc's record builder calls: `{ a: va, b: vb }.Engine.Signal` is a signal of the record, the way a decision reads several cells), `Signal.lift`, `Signal.lift_row` | [Thinking in Signals](@/docs/thinking-in-signals.md#signals-declare-what-they-read) |
| The store | `cell`, `table`, `Cells(whole, st, h)` (a description, built with the record builder: `{ a: .., b: .. }.Engine.Cells`; a store of one cell is `Engine.cell(init).map(\|c\| { c: c })`), `Cells.map`, `Cells.map2`, `Cells.with_reset`, `store`, `Stored(tag, st)`, `Store(st, h)`, `Store.cells`, `Store.with_initial`, `Store.after`, `Store.read` | [Shared State](@/docs/shared-state.md) |
| Cells and writes | `Cell(st, a)`, `Cell.signal`, `Cell.state`, `Cell.set`, `Cell.update`, `Write(st)` | [Shared State](@/docs/shared-state.md#writes-are-values) |
| Decisions | `handle`, `handle_by` (handlers), `handle_files`, `handle_files_by` (handlers of the files an event carries), `react`, `react_by` (reactions): each from one pure function that returns a `List(Write(st))`; `does` (a handler from a list of writes, for a transition that needs nothing from the event) | [Shared State](@/docs/shared-state.md#decisions) |
| State | `state`, `State(ctx, s)` (a piece of state as one context sees it, local or shared), `State.signal`, `State.lift`, `State.lift_row` | [Local State, Events, and Forms](@/docs/state-and-events.md) |
| Handlers | `Handler`, `State.update`, `State.update_by`, `State.set_value`, `State.set_value_by`, `Handler.also` (two handlers as one event), `Handler.lift`, `Handler.lift_row` | [Local State, Events, and Forms](@/docs/state-and-events.md#handlers) |
| Structure | `Elem`, `element`, `text`, `text_s`, `when`, `switch`, `remount_on`, `derive`, `resource`, `Remote(output, error)` (`request`: `Idle`, `Pending`; `answer`: `Unanswered`, `Answered(output)`, `Failed(error)`; `remote.answered()`, the latest answer as `Try(output, [NoAnswer])`), `gather` (one request per input), `Gathered(output, error)` (`jobs`: a `JobState` per input, `Working`, `Answered(output)` or `Failed(error)`; `all`: a `Remote` of the whole list) | [Conditionals and Lists](@/docs/dynamic-structure.md) |
| Lists | `each`, `RowRef`, `RowRef.key`, `RowRef.field`, `RowRef.item` (the whole item), `RowRef.select`, `keyed`, `Keyed` | [Conditionals and Lists](@/docs/dynamic-structure.md#keyed-lists) |
| Table views | `table_view`, `TableViewProps` (`query`, `plan`, `window`), `QueryPlan(k, v, s)` (`keep`, `sort`, `compare`), `Window` (`start`, `count`), `every_row` (the window that draws every row) | [Tables and Table Views](@/docs/tables-and-views.md) |
| Attributes | `Attr`, `attr`, `attr_s`, `class`, `class_s`, `test_id`, `test_id_s`, `ref` | |
| Events | `on` (event name, optionally `:prevent`), `on_click` | |
| Files | `File`, `File.name`, `File.size`, `File.mime`, `File.slice`, `File.spans` (the `{ start, len }` ranges of `n` bytes that cover a file, for `read!`), `Received`, `FilesHandler`, `State.on_files`, `handle_files`, `handle_files_by`, `FilesHandler.also` (two files handlers as one event), `on_files` | [Files](@/docs/files.md) |
| Operations on files | `File.upload` (`UploadProps`: `url`, `method ?? "POST"`, `headers ?? []`, `timeout ?? Unlimited`), `File.sha256`, `File.object_url` (acting where the browser keeps the file), `File.read_bytes`, `File.read_utf8` (reading it into the page; `ReadProps`: `max_bytes ?? 8388608`), `file_bytes`, `file_text`, `file_digest`, `file_url`, `FileError` (`Unreadable`, `TooLarge`, `InvalidUtf8`, `Unavailable`, `Refused`) | [Files](@/docs/files.md) |
| Saving and downloading | `File.save` (a download command; `SaveProps`: `name : [Same, Named(Str)]`), `File.fetch` (`FetchProps`: `url`, `method`, `headers`, `timeout : [Unlimited, Ms(U32)]`), `fetched`, `FetchError` (`Network`, `Timeout`, `Status`, `TooLarge`, `Refused`) | [Files in Tasks](@/docs/files-in-tasks.md) |
| Effects in a worker job | `File.read!` (`{ start, len }`) and `File.contents!`, answering `Try(_, [Unreadable])`, and `File.contents_utf8!`, `Try(Str, [Unreadable, InvalidUtf8])`; `Files.build!` (`import pf.Files`; `BuildProps`: `name`, `mime : [Auto, Mime(Str)] ?? Auto`, `start_from : [Empty, From(File)] ?? Empty`), `Builder`, `Builder.append!` (`Try({}, [TooLarge])`), `Builder.append_file!`, `Builder.finish!` | [Files in Tasks](@/docs/files-in-tasks.md) |
| Effects | `watch`, `watch_changes`, `watch_latest`, `on_post`, `Outbox(item)` (`outbox({})`, `box.post(item)`, `box.last()`: `Unposted` or `Posted(item)`), `Reaction`, `State.on_result`, `react`, `react_by`, `Reaction.also` (two reactions to one result), `ignore`, `on_cleanup`, `cleanup`, `Request`, `Result`, `HttpError`, `http_text`, `WorkFault`, `FileError`, and the plain data of port requests, `PortMessage`, `PortFailure` and `PortDelivery`, which the typed `Port` module wraps | [Effects and the Browser](@/docs/effects-and-browser.md) |

A component is not an API of its own: it is a type module whose view is
handed the cells it uses ([Components](@/docs/components.md)).

## Table

`Table(k, v)` is the value a table cell holds: rows by a key that has
equality and a hash (`import pf.Table`). A decision changes it inside
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

The module's remaining functions (`version`, `changes_start`,
`clear_changes`, `with_id`, `mark`, `kept`) are the engine's bookkeeping of
the changes. Each takes an `EngineOnly` as its last argument, a value only
the platform can make, so an app cannot call them.

## Html

`Html` is a typed vocabulary over `Engine.element`. Every helper is generic in
its context. Accessible names go in `aria-label`, which the spec locators
match. A helper ending `_s` takes a signal where its plain counterpart
takes a constant; `Html.p_s` takes reactive text, for example.

| Area | Helpers |
|---|---|
| Structure | `div`, `div_s`, `div_attrs`, `section`, `section_s`, `section_attrs`, `h1`, `h2`, `h2_s`, `h3`, `p`, `p_s`, `p_attrs`, `span_s`, `pre_s`, `ul`, `li`, `link`, `label_for` |
| Controls | `button`, `button_s`, `icon_button`, `action_button`, `submit_button`, `text_input`, `number_input`, `textarea`, `checkbox`, `radio`, `select`, `option`, `option_s`, `option_attrs`, `form`, `file_input` (`FileInputProps`: `selection : [Single, Multiple] ?? Single`, `accept : [Any, Types(Str)] ?? Any`) |
| Attributes | `aria_label`, `aria_label_s`, `aria_describedby`, `aria_invalid`, `disabled`, `flag`, `flag_maybe` |
| Events | `on_input`, `on_change`, `on_focus`, `on_blur`, `on_keydown`, `on_submit`, `on_drop_files`, `on_paste_files` |

`section(name, class, children)` names a region for assistive technology
and the spec locators (`aria-label`); it renders no heading, so put one
among the children for a visible title.

Anything else is `Engine.element(tag, attrs, children)`.

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

| Event | Payload |
|---|---|
| `click`, `submit` | empty |
| `input` | the control's value |
| `change` | `"true"` or `"false"` for a checkbox or radio, else the value |
| `keydown`, `keyup` | the key |
| `focus`, `blur` | the control's value |
| `change` on a file input, `drop`, `paste`, with `on_files` | the files, as `Received` (see [Files](@/docs/files.md)) |

## Attribute values

An empty value removes the attribute. `value` is the live control value,
guarded while the control has focus. `checked` is a property set from
`"true"`. `disabled`, `selected`, `readonly`, `required`, `hidden` and
`multiple` are present for any value other than `""` and `"false"`.

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
| `fetch` | the global `fetch` | The function HTTP requests go through, for a page that scripts its own backend | [Effects and the Browser](@/docs/effects-and-browser.md) |
| `manualEffects` | `false` | Requests wait until the caller answers or runs them (`runEffect`); used by the spec runner in Chrome | [Testing](@/docs/testing.md) |
| `manualWork` | `false` | Only worker jobs wait for `runEffect`; every other effect runs on its own; used by the repository's long sessions in Chrome | [Contributing](@/docs/contributing.md#walks-and-soaks) |

The browser tests also pass `manualIntervals` (intervals tick only when the
test says), `window` and `document`; an app's page has no reason to set
them.

## Limits

| Resource | Bound | At the bound |
|---|---|---|
| Awaited requests in flight | 32 (`max_inflight`) | The reaction receives `Refused` |
| Follow-up chain depth per event | 64 | Contract error |
| Follow-up turns per event | 64 per in-flight slot, at least 4096 | Resource limit |
| HTTP timeout | 600 s | Capped |
| Handlers for one event on one element | 1 | Contract error at mount; make one handler of two with `also` |
| Static attributes, children or holes per row template element | 255 | Resource limit |
| Live DOM nodes | 2³² − 2 | Resource limit |
| Events queued while a batch applies | 4096 | Resource limit |
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
| Undelivered messages per port subscription | 1 (`Latest`) or n ≤ 1024 (`Every(n)`) | `Latest` keeps the newest; `Every` refuses the JavaScript's `emit` |
| Port call timeout | 600 s | Capped |
| Payload nesting | 512 containers | The job is `Lost(Contract)`: an input fails to decode in the worker, an answer is refused there before it is sent |
| Bytes a job appends to its builders | `maxOutputBytes` (default 256 MiB); files appended by reference do not count | `append!` answers `Err(TooLarge)` |
| Files in one job's answer | 16 | The job is `Lost(Contract)`, nothing delivered |
| Room on the page for an answer's files | The page's free slots among its 64 | The job is `Lost(ResourceLimit)`, nothing delivered |
| Room on the page for a port's answer or message with files | The page's free slots among its 64 | `TooLarge`, none of its files kept |
| Files and builders one job holds at once | 64 | The job is `Lost(ResourceLimit)` |
| A fetched body | `maxFileBytes` (default 256 MiB) | `FileFailed(TooLarge)`, read by `fetched` as `Err(TooLarge)` |

## Errors

The engine never repairs invalid input. A broken contract stops the app with
a classified diagnostic naming the rule and, where there is one, the
construction site, for example `contract: duplicate key "r0" in each at site
/3/0`. The runtime keeps the last rendered page, reports the fault through
`onFault`, and refuses further events.

| Class | Cause |
|---|---|
| `contract` | A rule of the API was broken: a duplicate key in an `each`, a `switch` value outside its cases, a row template that is not a single element, two handlers for one event on one element, a decision whose list replaces a cell an earlier write of the same list wrote, `Table.insert` of a key already present, a table built from two rows with one key, two rows of a view that compare `Same`, a view's row read after its key left the table in the same event, a cleanup asking for a result, an effect feedback loop, an outbox posted twice in one turn, a worker task registered twice or asked for without being registered, a port declared twice or used without being declared or as another shape, a worker effect outside a job, a builder used after `finish!` or after the call that opened it returned, an answer holding more than 16 files, malformed boot or result bytes |
| `resource_limit` | A bound in the table above |
| `out_of_memory` | The Wasm heap could not grow |
| `app_crash` | `crash` in app code, or a Roc runtime error |
| `expect_failed` | A failed `expect` in a development build |
| `executor` | A bug in the browser runtime while applying commands |

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

The command stream, event records and boot bytes are versioned together. The
full wire protocol is Appendix B of
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).
