# Attribute / Event / Payload Boundary Design Prep

Temporary working note for expanding the Signals browser-facing UI boundary. This
is not an enduring design document yet. Its purpose is to capture requirements,
current constraints, candidate directions, and unresolved questions before the
final design is folded into `DESIGN.md`, `GUIDE.md`, and `NEXT_STEPS.md`.

Status: the first boundary/API shrink slice has landed. General text/boolean
attributes, named events, typed static event policy, keyboard payloads, submit
prevent-default, and the shared `BoundarySchema` / `EventExtractionPlan` record
path are now implemented. The remaining value of this note is the future
broadening work: optional attribute absence, more payload leaves only when a
canary needs them, and reuse of the boundary vocabulary beyond DOM events.

## Problem Statement

The original Signals UI boundary was intentionally small: apps could set a few
well-known fields and bind a few event kinds. That was useful for proving the
core engine, but too narrow for real production web apps.

The original closed surface was:

- text-like fields: `text`, `role`, `label`, `test_id`, `value`, `class`;
- bool fields: `checked`, `disabled`;
- event kinds: `click`, `input`, `check`, `pointer_down`, `pointer_up`,
  `pointer_enter`, `pointer_leave`;
- payload shapes: unit, string, bool;
- payload accessors: none, `target.value`, `target.checked`.

The current surface is no longer closed in the same way. `Html.attr`,
`Html.attr_s`, `Html.bool_attr`, and `Html.bool_attr_s` cover arbitrary named
attributes; `Html.on_event` covers arbitrary named DOM events with typed static
policy; and `Ui.State.on_key` proves a non-scalar record payload through the
boundary. Remaining gaps include optional attribute absence, namespace-sensitive
attributes where required, broader payload leaves such as pointer coordinates or
file metadata, and using the same boundary vocabulary for non-event host input.

The goal is to generalize the boundary without losing the properties that make
the current engine tractable:

- Roc apps describe explicit data; hosts do not infer meaning from the DOM.
- The JS runtime remains a thin executor, not a reactive runtime.
- Hot paths can still use specialized representations where measured.
- Typed Roc values remain protected by confined erasure; JS never decodes Roc
  layouts.

## Current Context

Relevant current files:

- `platform/Node.roc`
  - `Attr` carries typed `TextField` / `BoolField` wrappers and one
    `On(EventBinding)` constructor.
  - `Msg` carries typed `BoundarySchema` and `EventExtractionPlan` byte wrappers;
    public payload-kind/accessor constants and compatibility event-message
    constructors have been removed.
  - `EventBinding` carries typed `EventPolicy` and `EventDelivery`; listener
    option bits are now a browser command-wire detail, not a Roc ABI field.
- `platform/Html.roc`
  - exposes attribute/event sugar and owns file-local lowering data for built-in
    fields and fixed event kinds.
- `platform/Ui.roc`
  - constructs reducer messages from file-local boundary/extraction descriptors.
    The remaining descriptor byte values are temporary until the wasm key-shift
    allocation regression has a smaller fix.
- `src/signals/boundary.zig`
  - parses and validates the shared boundary schema and DOM event extraction
    plan.
- `src/signals/engine.zig`
  - collects descriptor streams for text attrs, bool attrs, and event descriptors.
  - routes source updates to signal graph records.
- `src/signals/render_commands.zig`
  - owns fixed render op ids and command-buffer record shape.
- `www/static/signals.mjs`
  - applies integer patch ops to DOM nodes and marshals event payloads back to
    `roc_ui_event`.
- `scripts/browser/runtime_contract.test.mjs`
  - protects the JS↔WASM contract surface.

The core direction is now settled: carry explicit boundary schema and producer
descriptors in the descriptor tree so JS serializes only requested leaves.

## Requirements

### Expressiveness

The app-facing API must be able to describe common web UI without host changes
for every field:

- arbitrary static text attributes: `id`, `href`, `src`, `alt`, `title`,
  `placeholder`, `name`, `type`, `autocomplete`, etc.;
- arbitrary signal-backed text attributes;
- arbitrary static/signal-backed boolean attributes where boolean DOM semantics
  apply;
- `aria-*` and `data-*` attributes;
- event handlers for common browser events beyond the current fixed set;
- event payloads that can include selected event/target/currentTarget fields;
- prevent-default / stop-propagation policy, either per binding or per event
  result;
- namespace-sensitive attributes where required, especially SVG.

### Safety and Model Discipline

- Host and JS must not recover meaning from DOM state that was not explicitly
  declared by Roc.
- Event payload extraction must be declared by the descriptor, not ad hoc JS logic
  per app.
- JS must serialize only the requested payload leaves.
- The event payload format crossing into WASM must remain layout-independent from
  Roc values.
- The host must keep ownership and lifetime of retained Roc callbacks and values.
- Invalid or unsupported boundary declarations should become diagnostics or host
  errors with clear messages; they should not silently degrade into wrong DOM
  behavior.

### Performance

- Keep specialized fast paths for hot fields if metrics justify them:
  `textContent`, `class`, `value`, `checked`, `disabled`, and common events.
- General attributes/events should be efficient enough for ordinary app code, but
  do not need to be over-optimized before real measurements exist.
- The descriptor stream should not grow many sparse per-field tables for every
  new web attribute.
- Event marshalling should avoid serializing full event objects.

### Testability

- Native specs should be able to assert behavior through semantic locators where
  possible.
- JS contract tests should cover payload extraction, listener options, attribute
  application/removal, and memory-view refresh after event payload allocation.
- The app suite should add the smallest examples that prove new classes of
  boundary behavior, not catalog every HTML attribute.

## Candidate Direction

### 1. Split hot fields from general fields

Keep existing specialized field ids for hot fields and introduce general
attribute descriptors for the open-ended browser surface.

Possible Roc-level shape:

```roc
Attr := [
    StaticText({ field : TextField, name : Str, value : Str }),
    SignalText({ field : TextField, name : Str, signal : Box(SignalExpr), read : TextReadHandle }),
    StaticBool({ field : BoolField, name : Str, value : Bool }),
    SignalBool({ field : BoolField, name : Str, signal : Box(SignalExpr), read : BoolReadHandle }),
    On(EventBinding),
]

EventDelivery := { native : Bool }

EventBinding := { kind : FixedEventKind, msg : Msg, policy : EventPolicy, delivery : EventDelivery, name : Str }
```

This is the current shape. `Html` hides the built-in field/event ids and exposes
general named attrs/events as sugar over the same descriptor records. The
remaining question is whether a later wire format should keep the `name` string
inline, move it through a string table, or add an interned string ref.

### 2. Make payload access explicit data

Instead of `payload_kind` plus one hard-coded accessor id, an event binding should
carry a payload descriptor. The descriptor says what JS should read from the
browser event and how to encode it.

Possible minimal stages:

1. keep existing unit/string/bool payloads, but generalize the accessor name;
2. add records composed of primitive leaves;
3. add lists only if a real event requires them;
4. add app-defined payload decoders only if static descriptors are insufficient.

Example descriptor concepts:

```text
PayloadSpec =
  unit
  text(EventPath)
  bool(EventPath)
  float(EventPath)
  int(EventPath)
  record(List({ field_name, spec }))

EventPath =
  event.key
  event.code
  event.clientX
  target.value
  target.checked
  target.files.length
  currentTarget.dataset.foo
```

JS executes this descriptor against the event object and writes a boundary format
into WASM memory. The host passes the payload bytes to the retained Roc reducer
through the correct typed capability.

### 3. Listener options and event policy

Real apps need at least:

- `preventDefault`;
- `stopPropagation`;
- capture vs bubble;
- passive listeners for scroll/touch where appropriate;
- maybe once.

Static prevent/stop/listener options now live on the binding as typed
`Node.EventPolicy` data exposed through `Html`. Dynamic results remain deferred
until a maintained app or canary proves a state-dependent response is needed.

### 4. Attribute removal semantics

Signal-backed optional attributes require explicit absence semantics. Do not use
empty string as a sentinel.

Options:

- add `SignalAttrMaybe : Signal([None, Some(Str)])`;
- model boolean attrs separately and remove when false;
- provide convenience APIs in `Html` while keeping a small core descriptor.

## Requirements for Research Spikes

1. Build a small app with:
   - `href`, `aria-label`, `data-*`, `id`, `placeholder`;
   - static and signal-backed variants;
   - keyboard event with `{ key, shift_key }` payload;
   - submit event with prevent-default.
2. Prove native spec runner can assert the important behavior without becoming a
   browser duplicate.
3. Prove JS contract tests can validate event payload extraction through the
   command/event boundary.
4. Measure command-buffer growth and event payload allocation for the generalized
   path vs current specialized path.

## Outstanding Questions

- Should general attributes be strings only initially, or should typed numeric / token / URL helpers exist at the API layer?
- How should invalid attribute names be handled? Reject at build/ingest time, sanitize, or pass through?
- Should `style` be a raw string, a list/map of declarations, or both?
- How should SVG namespaces be represented?
- How much accessibility policy belongs in helpers vs raw attrs? For example,
  should `button` set role automatically, or should native tag semantics be used?
- Should event names be unrestricted strings or a curated enum plus custom escape hatch?
- What is the minimal event payload shape needed for keyboard, submit, pointer,
  clipboard, drag/drop, and file input?
- Are payload descriptors app-authored directly, or hidden behind typed helpers
  like `Html.on_key_down`?
- Can payload extraction failures be represented as reducer non-delivery with a
  diagnostic, or must every payload extractor be total?
- How do we preserve `expect_metric_delta` work-budget assertions when general
  attr/event descriptor tables are added?

## Dependencies and Sequencing

This layer sits **on top of** the wire protocol and **underneath** forms:

- It depends on `WIRE_PROTOCOL_DESIGN_PREP.md` for the general
  `SetAttr`/`RemoveAttr`/`BindEvent` ops, the name/string reference table, and the
  event payload byte format. Do not design the descriptor shape here without
  co-designing its wire encoding there.
- `CONTROLLED_INPUTS_FORMS_DESIGN_PREP.md` is a primary consumer: form controls
  need `type`, `name`, `required`, `aria-*`, and `submit`/`focus`/`blur`/keyboard
  events. The current general attr/event surface covers these basics.
- Static prevent-default/stop-propagation policy now covers submit and nested
  control canaries. Broader default-action modeling should be added only with a
  focused semantic test.

Recommended order: settle the protocol encoding, then this boundary, then use the
forms milestone to exercise both end to end.

## Next Milestone

The original thin slice is complete: general attrs, keyboard record payload,
submit prevent-default, native descriptor support, browser command/event support,
focused app/spec coverage, and JS contract coverage exist.

The next boundary slice should remove or prove one remaining temporary edge:

- remove the file-local `Ui` boundary/extraction byte values once the wasm
  key-shift descriptor allocation regression has a smaller fix; or
- add optional attribute absence if a maintained app needs signal-backed removal;
  or
- add one new boundary leaf only with an app/spec canary, native semantic
  coverage, and JS validation/extraction-failure coverage.

Do not broaden the browser catalog speculatively.
