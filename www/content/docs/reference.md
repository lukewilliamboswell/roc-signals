+++
title = "Reference"
description = "The Engine, Html, Worker, Wire, Port and PortJson APIs at a glance, the platform's limits, and its error classes."
weight = 13
template = "page.html"
+++

# Reference

The [API documentation](../../api/api/) is generated from the platform's source
and documents every public symbol of `Engine`, `Html`, `Worker`, `Wire`, `Port` and `PortJson`:
the authoring API, and nothing else. Every `Engine` type is opaque; the engine's implementation
and the interfaces its hosts and test harnesses use live in the platform's
internal `Core` module, which apps cannot import. This page is the map of it. The spec language is in [Testing](@/docs/testing.md).

## Engine

| Area | Symbols |
|---|---|
| Programs | `program`, `program_boot`, `Program`, `Program.with_workers`, `registration`, `Registration`, `Program.with_ports`, `PortDecl`, `Boot`, `boot_storage` |
| Contexts | `Root`, `In(outer, s)`, `Row(outer, item)`, `Comp(p, a)` |
| Values | `Val`, `const`, `Val.map`, `Val.map2`, `Val.lift`, `Val.lift_row` |
| State | `state`, `State`, `State.val`, `State.lift`, `State.lift_row` |
| Handlers | `Handler`, `State.update`, `State.update_by`, `State.set_value`, `State.set_value_by` |
| Structure | `element`, `text`, `text_v`, `when`, `switch`, `derive`, `resource`, `Remote(output, error)` (`request`: `Idle`, `Pending`; `answer`: `Unanswered`, `Answered(output)`, `Failed(error)`) |
| Lists | `each`, `RowRef.key`, `RowRef.field`, `RowRef.select`, `keyed` |
| Attributes | `attr`, `attr_v`, `class`, `class_v`, `test_id`, `test_id_v`, `ref` |
| Events | `on` (event name, optionally `:prevent`), `on_click` |
| Files | `File`, `File.name`, `File.size`, `File.mime`, `File.slice`, `File.contents`, `File.contents_utf8` (in a worker program), `Received`, `FilesHandler`, `State.on_files`, `on_files` |
| Operations on files | `File.upload`, `File.sha256`, `File.object_url` (acting where the browser keeps the file), `File.read_bytes`, `File.read_utf8` (reading it into the page), `file_bytes`, `file_text`, `file_digest`, `file_url`, `FileError` (`Unreadable`, `TooLarge`, `InvalidUtf8`, `Unavailable`, `Refused`) |
| Components | `component`, `State.push`, `State.push_by`, `State.push_value_by`, `sink`, `split` |
| Effects | `watch`, `on_change`, `latest`, `State.on_result`, `ignore`, `on_cleanup`, `cleanup`, `Req`, `Res`, `HttpError`, `http_text`, `WorkFault`, `FileError` |

## Html

`Html` is a typed vocabulary over `Engine.element`. Every helper is generic in
its context. Accessible names go in `aria-label`, which the spec locators
match.

| Area | Helpers |
|---|---|
| Structure | `div`, `div_v`, `div_attrs`, `section`, `section_v`, `section_attrs`, `h1`, `h2`, `h2_v`, `h3`, `p`, `p_v`, `p_attrs`, `span_v`, `pre_v`, `ul`, `li`, `link`, `label_for` |
| Controls | `button`, `button_v`, `icon_button`, `action_button`, `submit_button`, `text_input`, `number_input`, `textarea`, `checkbox`, `radio`, `select`, `option`, `option_v`, `option_attrs`, `form`, `file_input` |
| Attributes | `aria_label`, `aria_label_v`, `aria_describedby`, `aria_invalid`, `disabled`, `flag`, `flag_maybe` |
| Events | `on_input`, `on_change`, `on_focus`, `on_blur`, `on_keydown`, `on_submit`, `on_drop_files`, `on_paste_files` |

Anything else is `Engine.element(tag, attrs, children)`.

## Worker

`Worker` runs pure Roc functions in Web Workers; see
[Workers](@/docs/workers.md).

| Area | Symbols |
|---|---|
| Programs | `Program(input, output)`, `program`, `fallible`, `ProgramProps(input, output)` (`name`, `run`, `deadline : [Unlimited, Ms(U32)] ?? Unlimited`), `Program.registration` |
| Runs from an effect site | `Program.request`, `Program.result`, `Error` (`Timeout`, `Refused`, `Lost(WorkFault)`, `FileFailed(FileError)`) |
| Layers | `derive`, `derive_when` (for a program or a query), holding an `Engine.Remote(output, Error)` |
| Prepared programs | `prepared`, `PreparedProps(init, state)` (`name`, `prepare`), `Prepared(init, state)`, `Prepared.query`, `Prepared.fallible_query`, `QueryProps(state, q, out)` (`name`, `run`, `deadline`, `on_cancel : Cancel ?? Stop`), `Prepared.registration`, `Query(init, state, q, out)`, `Query.registration`, `QueryRegistration(state)`, `Query.request`, `Query.result`, `Question(init, q)` (`input`, `query`), `Cancel` (`Stop`, `Finish`) |

## Wire

`Wire` is the binary format of worker payloads. Apps rarely call it: a
program's types decide what is sent.

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
| Declaring | `command`, `call`, `subscription`, `Delivery` (`Latest`, `Every(n)`), `Call.with_timeout_ms`, and each shape's `declaration` for `Program.with_ports` |
| From an effect site | `Command.send`, `Call.request`, `Call.result`, `Subscription.subscribe`, `Subscription.message`, `Error` (`Refused`, `Timeout`, `Threw(message)`, `TooLarge`, `Closed`, `Undecodable(why)`) |
| Layers | `derive`, `derive_when` (for a call), holding an `Engine.Remote(output, Error)` |

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

## Limits

| Resource | Bound | At the bound |
|---|---|---|
| Awaited requests in flight | 32 (`max_inflight`) | The reaction receives `Refused` |
| Follow-up chain depth per event | 64 | Contract error |
| Follow-up turns per event | 64 per in-flight slot, at least 4096 | Resource limit |
| HTTP timeout | 600 s | Capped |
| Nested state, derive or list layers in one component | 63 | Resource limit |
| Static attributes, children or holes per row template element | 255 | Resource limit |
| Live DOM nodes | 2³² − 2 | Resource limit |
| Events queued while a batch applies | 4096 | Resource limit |
| Worker programs in a catalogue | 64 names: programs, preparations and their queries | Contract error at mount |
| Work deadline | 600 s | Capped |
| Workers alive at once | `maxWorkers` (default the core count, at most 8) | Runs wait in order for a free worker |
| Prepared states | One per worker | A new input replaces the least recently used idle worker's |
| A worker's memory | `maxWorkerBytes` (default 128 MiB), checked after each run | The worker is ended after the run, its prepared state with it |
| Files an app holds at once | 64 | Further files are not delivered; `Received.refused` counts them |
| Files one worker run reads | 16, and `maxFileBytes` bytes (default 256 MiB) | The run fails unread: `FileFailed(TooLarge)` |
| Bytes one page read takes | `maxReadBytes` (default 8 MiB) | `FileFailed(TooLarge)`, unread |
| Bytes one digest reads | `maxFileBytes` (default 256 MiB) | `FileFailed(TooLarge)`, unread |
| URLs one file gives | 16 ranges, revoked when the file is let go | `FileFailed(TooLarge)` |
| Ports a program declares | 64, names 1 to 128 bytes | Contract error at mount |
| A port's answer or message | `maxPayloadBytes` (default 4 MiB, at most 64 MiB) | `TooLarge` |
| Undelivered messages per port subscription | 1 (`Latest`) or n ≤ 1024 (`Every(n)`) | `Latest` keeps the newest; `Every` refuses the JavaScript's `emit` |
| Port call timeout | 600 s | Capped |
| Payload nesting | 512 containers | The run is `Lost(Contract)`: an input fails to decode in the worker, an output is refused there before it is sent |

## Errors

The engine never repairs invalid input. A broken contract stops the app with
a classified diagnostic naming the rule and, where there is one, the
construction site, for example `contract: duplicate key "r0" in each at site
/3/0`. The runtime keeps the last rendered page, reports the fault through
`onFault`, and refuses further events.

| Class | Cause |
|---|---|
| `contract` | A rule of the API was broken: a duplicate key, a `switch` value outside its cases, a row template that is not a single element, a cleanup asking for a result, an effect feedback loop, a worker program registered twice or asked for without being registered, a port declared twice or used without being declared or as another shape, malformed boot or result bytes |
| `resource_limit` | A bound in the table above |
| `out_of_memory` | The Wasm heap could not grow |
| `app_crash` | `crash` in app code, or a Roc runtime error |
| `expect_failed` | A failed `expect` in a development build |
| `executor` | A bug in the browser runtime while applying commands |

`recover()` on the runtime mounts a fresh instance from the same module.

A fault inside a worker program stops only that worker. Its run answers
`WorkLost` with the class (`Lost(fault)` in `Worker.Error`), the diagnostic
goes to the console and `onWorkerFault`, and the page keeps working.
`WorkLost` also reports `unavailable` (the browser has no workers) and
`executor` (the worker script itself failed).

Nothing a port's JavaScript does stops the app. A call whose handler throws,
rejects or answers something that is not JSON data answers `Threw`; a
command handler's failure goes to the console and `onPortFault`. A page
whose `ports` option does not match the app's declarations is refused before
it mounts.

## Protocol

The command stream, event records and boot bytes are versioned together. The
full wire protocol is Appendix B of
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).
