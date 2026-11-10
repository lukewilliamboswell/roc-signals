+++
title = "Reference"
description = "The Engine, Html, Worker and Wire APIs at a glance, the platform's limits, and its error classes."
weight = 12
template = "page.html"
+++

# Reference

The [API documentation](../../api/api/) is generated from the platform's source
and documents every public symbol of `Engine`, `Html`, `Worker` and `Wire`:
the authoring API, and nothing else. Every `Engine` type is opaque; the engine's implementation
and the interfaces its hosts and test harnesses use live in the platform's
internal `Core` module, which apps cannot import. This page is the map of it. The spec language is in [Testing](@/docs/testing.md).

## Engine

| Area | Symbols |
|---|---|
| Programs | `program`, `program_boot`, `Program`, `Program.with_workers`, `registration`, `Registration`, `Boot`, `boot_storage` |
| Contexts | `Root`, `In(outer, s)`, `Row(outer, item)`, `Comp(p, a)` |
| Values | `Val`, `const`, `Val.map`, `Val.map2`, `Val.lift`, `Val.lift_row` |
| State | `state`, `State`, `State.val`, `State.lift`, `State.lift_row` |
| Handlers | `Handler`, `State.update`, `State.update_by`, `State.set_value`, `State.set_value_by` |
| Structure | `element`, `text`, `text_v`, `when`, `switch`, `derive`, `resource` |
| Lists | `each`, `RowRef.key`, `RowRef.field`, `RowRef.select`, `keyed` |
| Attributes | `attr`, `attr_v`, `class`, `class_v`, `test_id`, `test_id_v`, `ref` |
| Events | `on` (event name, optionally `:prevent`), `on_click` |
| Components | `component`, `State.push`, `State.push_by`, `State.push_value_by`, `sink`, `split` |
| Effects | `watch`, `on_change`, `latest`, `State.on_result`, `ignore`, `on_cleanup`, `cleanup`, `Req`, `Res`, `HttpError`, `http_text`, `WorkFault` |

## Html

`Html` is a typed vocabulary over `Engine.element`. Every helper is generic in
its context. Accessible names go in `aria-label`, which the spec locators
match.

| Area | Helpers |
|---|---|
| Structure | `div`, `div_v`, `div_attrs`, `section`, `section_v`, `section_attrs`, `h1`, `h2`, `h2_v`, `h3`, `p`, `p_v`, `p_attrs`, `span_v`, `pre_v`, `ul`, `li`, `link`, `label_for` |
| Controls | `button`, `button_v`, `icon_button`, `action_button`, `submit_button`, `text_input`, `number_input`, `textarea`, `checkbox`, `radio`, `select`, `option`, `option_v`, `option_attrs`, `form` |
| Attributes | `aria_label`, `aria_label_v`, `aria_describedby`, `aria_invalid`, `disabled`, `flag`, `flag_maybe` |
| Events | `on_input`, `on_change`, `on_focus`, `on_blur`, `on_keydown`, `on_submit` |

Anything else is `Engine.element(tag, attrs, children)`.

## Worker

`Worker` runs pure Roc functions in Web Workers; see
[Workers](@/docs/workers.md).

| Area | Symbols |
|---|---|
| Programs | `Program(input, output)`, `pure`, `fallible`, `Program.with_deadline_ms`, `Program.registration` |
| Runs from an effect site | `Program.request`, `Program.result`, `Error` (`Timeout`, `Refused`, `Lost(WorkFault)`) |
| Layers | `derive`, `derive_when`, `Remote(output)` (`running`, `answer`: `Nothing`, `Done(output)`, `Failed(Error)`) |

## Wire

`Wire` is the binary format of worker payloads. Apps rarely call it: a
program's types decide what is sent.

| Area | Symbols |
|---|---|
| Payloads | `Sendable`, `encode`, `decode`, `Error` |
| Bulk bytes | `Bytes`, `Bytes.from_list`, `Bytes.to_list` |
| Derivation | `Format`, `State`: the hooks the compiler's codec derivation calls; apps never use them |

## Event payloads

| Event | Payload |
|---|---|
| `click`, `submit` | empty |
| `input` | the control's value |
| `change` | `"true"` or `"false"` for a checkbox or radio, else the value |
| `keydown`, `keyup` | the key |
| `focus`, `blur` | the control's value |

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
| Worker programs in a catalogue | 64 | Contract error at mount |
| Work deadline | 600 s | Capped |
| Workers alive at once | `maxWorkers` (default the core count, at most 8) | Runs wait in order for a free worker |
| Payload nesting | 512 containers | An input: the run is `Lost`; an output: contract error |

## Errors

The engine never repairs invalid input. A broken contract stops the app with
a classified diagnostic naming the rule and, where there is one, the
construction site, for example `contract: duplicate key "r0" in each at site
/3/0`. The runtime keeps the last rendered page, reports the fault through
`onFault`, and refuses further events.

| Class | Cause |
|---|---|
| `contract` | A rule of the API was broken: a duplicate key, a `switch` value outside its cases, a row template that is not a single element, a cleanup asking for a result, an effect feedback loop, a worker program registered twice or asked for without being registered, malformed boot or result bytes |
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

## Protocol

The command stream, event records and boot bytes are versioned together. The
full wire protocol is Appendix B of
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).
