# Event Propagation And Listener Policy

Deferred design note for the remaining DOM event work in Signals: handler chains,
dynamic event response, broader payload leaves, and measured delivery choices.
The shared boundary model, canonical `EventBinding`, typed static policy, and
current extraction-plan payload surface have shipped, so future work here must
extend those paths instead of adding a duplicate event-specific payload or policy
surface. Judge the design below against the requirements of expert frontend work
and the goal of a smaller public API.

Refresh check: re-run on 2026-07-04 with the focused browser event contract,
Zig event/boundary/spec-runner subset, and full native spec suite. Current
static-policy, event-delivery, boundary payload, response-bit, and native event
flow claims below remained green; dynamic response and handler chains remain
unpromoted.

## Executive Decision

Event propagation control should be modeled as first-class event binding policy,
orthogonal to event name, payload shape, and state reducer.

Do not add helpers such as `on_pointer_down_stop_propagation`. That shape does
not scale. Every browser event can combine several independent concerns:

- event type: `click`, `pointerdown`, `keydown`, `submit`, custom events;
- event phase: capture vs bubble;
- listener options: passive, once, abort/lifecycle;
- filtering: self target, trusted event, maybe composed path constraints;
- default action policy: allow or prevent;
- propagation policy: continue, stop, or stop immediate;
- payload extraction: unit, target value, key metadata, pointer coordinates,
  clipboard data, files, drag data, custom event detail;
- delivery strategy: native listener vs delegated listener.

The platform should expose these as typed policy and payload values over the same
shared boundary model used by subscriptions, app interop, and structured effects.
High-level helpers can remain ergonomic, but they must compile to the same
canonical event descriptor as the low-level API. Compatibility helpers should be
migration shims, not permanent design centers.

The ideal model is:

```roc
Event.HandlerBinding(a) := {
    policy : Event.Policy(a),
    payload : Event.Payload(a),
    handler : Ui.State(model).On(a),
}

Event.Binding(a) := {
    type : Event.Type,
    phase : Event.Phase,
    delivery : Event.Delivery,
    handlers : List(Event.HandlerBinding(a)),
}

Html.on : Event.Binding(a) -> Html.Attr
```

Most application code should continue to use focused helpers that already lower
to canonical bindings:

```roc
Html.button("Save", state.on_unit(save))
Html.on_submit_prevent_default(state.on_unit(submit))
Html.on_key_down(state.on_key(handle_key))
Html.on_event("pointerdown", Html.event_policy_stop_propagation, state.on_unit(start_drag))
```

The future lower-level API should remain a single canonical escape hatch:

```roc
Html.on(
    Event.bind("pointerdown")
        |> Event.native
        |> Event.capture
        |> Event.prevent_default
        |> Event.stop_propagation
        |> Event.payload(Event.pointer)
        |> Event.handle(board_state.on_pointer(start_drag))
)
```

The exact Roc syntax can change. The invariant is that policy is data, not part
of the helper name.

## Status

The shared boundary consolidation and the static-policy slice have shipped:

- the shared boundary payload descriptor model exists. Roc carries
  `Node.EventExtractionPlan` bytes selected by the internal platform
  `EventExtraction` module; `src/signals/boundary.zig` parses those bytes,
  validates the shared schema tags and DOM extraction leaves, and derives the
  host `BoundaryPayloadDescriptor`;
- fixed and named host descriptors live in one internal event descriptor
  family; the public Roc attr shape carries `On(EventBinding)`;
- event policy is typed semantic data in Zig; option bits exist only at the
  browser wire edge;
- static policy (default/propagation/capture/passive/once/`self`/`trusted`) is
  expressible over the canonical descriptor without parallel helper families;
- `roc_ui_event` returns event-response bits, and the browser listener path
  validates that returned bits contain only prevent-default / propagation
  controls, applies them before draining event response commands, and fails
  closed on unsupported bits. Static Roc handlers still return zero, so dynamic
  response can use this ABI later without another break;
- fixed and named bindings normalize to the same JS listener object, and native
  listeners are used whenever requested policy requires native event-flow
  semantics;
- fixed-event opcodes are now documented and tested as wire compression for
  canonical fixed bindings; the browser derives matching Auto -> Native
  delivery reasons from fixed binding traits;
- Roc-side event extraction descriptor byte values now live in the unexposed
  internal `EventExtraction` platform module instead of in `Ui`;
- native spec-runner event flow covers `real_click`
  (`pointerdown -> pointerup -> click` with capture/bubble, stop policy,
  `self`/`trusted` filters), explicit/implicit submit-button default action and
  `type="button"` opt-out, reset-button default action for app-managed forms,
  checkbox checked-change default action, radio target-value change default
  action, single-value select option default action, Enter-key text-input form
  submit default action, direct submit, and disabled targets.

What remains from this document, with promotion gates:

1. dynamic response from `state.on_event`-style handlers, gated on a real
   canary need;
2. handler chains — ordered multi-handler bindings with one event turn and one
   command drain, gated on same-event composition pressure or on a promoted
   dynamic-response slice that needs a binding-level handler shape. An initial
   implementation may still reject multiple stateful handlers after
   canonicalization while preserving the target descriptor shape;
3. delegated delivery as an internal `Auto` optimization, gated on measurement.

Default-action modeling is no longer a standing backlog item. Add another
simulation only when a maintained app or focused canary proves a new semantic
need.

Event-specific payload formats must not be added; event payloads use the shared
boundary model.

## Focused Gates

For design-only edits that do not change current event-model, boundary payload,
delivery, or native event-flow status claims, run:

```sh
git diff --check
zig build run-check-tidy
```

For current event-model, boundary payload, delivery, and native event-flow status
claims, run the focused browser and Zig gates:

```sh
node --test --test-name-pattern "event|payload|submit|listener|delivery|form" scripts/browser/runtime_contract.test.mjs
zig build run-test-zig -Dtest-filter=event -Dtest-filter=boundary -Dtest-filter="spec runner"
```

For app-facing native behavior that depends on event flow or default actions, add
the native spec gate:

```sh
python3 scripts/test.py native --native always
```

## Why This Matters

The release planner bug exposed two separate issues:

1. The app needed to say "this nested button is a button, not a drag gesture
   starter." That is an event propagation requirement, not a card/reorder
   requirement.
2. The native spec runner's `click` did not model the browser sequence
   `pointerdown -> pointerup -> click` with bubbling, so it did not reproduce
   the failure until browser-level probing.

Adding one stop-propagation helper for the specific event would only hide the
first issue and leave the API surface on a bad path. The framework needs an
event model that can express browser event-flow policy explicitly, and the test
model needs to dispatch events through that policy.

## Prior Art

The browser primitive is `addEventListener(type, listener, options)`. The options
object includes `capture`, `once`, `passive`, and `signal`; `passive` also
constrains whether `preventDefault()` can be meaningful. Reference:
https://developer.mozilla.org/en-US/docs/Web/API/EventTarget/addEventListener

React exposes the event object to handlers. Handlers call
`stopPropagation()` and `preventDefault()` imperatively, and capture handlers are
spelled with a `Capture` suffix. This is flexible, but it relies on user code
touching the event object directly. Reference:
https://react.dev/learn/responding-to-events

Vue keeps handler logic cleaner by modeling common policies as event modifiers:
`.stop`, `.prevent`, `.self`, `.capture`, `.once`, and `.passive`. Vue also notes
that modifier ordering matters and that `.passive` should not be combined with
`.prevent`. Reference:
https://vuejs.org/guide/essentials/event-handling.html

Svelte has a similar modifier model and includes the extra controls expert
frontend engineers expect: `stopImmediatePropagation`, `nonpassive`, `self`, and
`trusted`. It also allows modifiers to be chained. Reference:
https://svelte.dev/docs/svelte/legacy-on

Elm exposes a more typed lower layer: ordinary helpers for common events, plus
`stopPropagationOn`, `preventDefaultOn`, and `custom`, where the decoder can
return a message and event-policy booleans. That shape is especially relevant
for Signals because it keeps DOM event details at the boundary while preserving
typed messages. Reference:
https://github.com/elm/html/blob/master/src/Html/Events.elm

Solid's event documentation makes a critical implementation point: delegated
events are cheaper for common events, but propagation control can behave
differently because the actual listener is on `document`; Solid recommends a
native listener when `stopPropagation()` needs native semantics. Reference:
https://docs.solidjs.com/concepts/components/event-handlers

The conclusion from these systems is consistent:

- policy must be orthogonal to event type;
- expert users need a low-level escape hatch;
- helpers should be compositional modifiers, not a combinatorial list of names;
- delegation is an optimization with semantic constraints, not a transparent
  replacement for native event flow.

## Current Implementation Shape

Relevant current files:

- `platform/Node.roc`
  - `Attr` has one `On(EventBinding)` variant. Fixed bindings carry a typed
    `FixedEventKind`; named bindings carry a name plus typed `EventPolicy` and
    `EventDelivery`.
  - `EventBinding` carries typed `EventPolicy` and `EventDelivery` through the
    Roc ABI. The current policy data includes static default/propagation
    controls, listener phase/options, and `self`/`trusted` filters.
  - `Msg` carries `EventExtractionPlan` bytes. Shared schema tags are embedded in
    those bytes; the host derives a parsed boundary payload descriptor from them
    during ABI ingest.
- `platform/Html.roc`
  - fixed helpers such as `on_pointer_down` lower through file-local
    fixed-kind/event-binding constructors.
  - `on_event` accepts typed `EventPolicy` and is currently the common escape
    hatch.
  - `on_event_delivery` accepts typed `EventPolicy` and `EventDelivery` for the
    low-level cases that must explicitly request `Html.event_delivery_native`;
    `on_event` and `on_custom` use `Html.event_delivery_auto`.
- `src/signals/descriptor_stream.zig`
  - stores fixed and named event descriptors in one `EventDesc` table, with
    fixed and named per-element indexes as lookup views.
  - named event descriptors retain typed `EventPolicy` and an `EventDelivery`
    request; raw listener bits are no longer stored in the active descriptor
    stream.
- `src/signals/boundary.zig`
  - owns the host-side payload container ids, shared schema bytes, and DOM
    extraction-plan ids. ABI ingest derives parsed payload descriptors from
    Roc's descriptor bytes. The parser structurally validates the minimal shared
    schema vocabulary (`unit`, `text`, `bool`, non-empty records of primitive
    leaves) and DOM extraction-plan bytes, rejecting empty or nested records while
    native dispatch remains limited to the current compact descriptor canaries.
    Canonical schema bytes are owned by supported extraction plans/descriptors,
    not by the generic payload container id.
- `src/signals/render_cache.zig`
  - stores fixed and named bindings with one `EventBinding` payload shape. Fixed
    bindings still use per-kind slots so hot-event lookup keeps its scan budget.
- `src/signals/render_sink.zig`
  - engine-facing sinks receive one `EventBindingKey` plus one `EventBinding`
    shape carrying typed `EventPolicy` and derived delivery. The native host
    adapter receives one `EventBindCommand` / `EventClearCommand` record; the
    remaining fixed/named choice is local host encoding or simulated-DOM storage.
- `src/wasm_host.zig`
  - event binding emits from one `EventBindCommand` record. Fixed events still
    encode as fixed opcodes; named events encode as dynamic `BindEvent`
    records with names, listener-policy bits derived from `EventPolicy`, and
    requested/effective delivery plus the derivation reason.
- `www/static/signals.mjs`
  - fixed and dynamic bind commands decode into one event-binding command shape
    before listener installation and command description. Fixed bindings carry
    their legacy pointer-default policy and derive delivery from fixed traits;
    named bindings carry listener options and requested/effective delivery.
    `self`/`trusted` filters run before static listener policy and reducer
    delivery.
- `src/sim_dom.zig`
  - fixed and named native bindings store one `EventBinding` payload shape and
    apply through one bind/clear helper. Fixed bindings still use per-kind slots
    for fast lookup.
- `src/spec/spec_runner.zig`
  - `real_click` dispatches `pointerdown -> pointerup -> click` through the
    simulated DOM propagation path, runs named capture handlers before bubble
    handlers, treats injected user actions as trusted, applies `self` filters,
    honors static stop/stop-immediate policy, and applies explicit/implicit
    submit-button default action for buttons inside forms when click policy did
    not prevent default while respecting `type="button"` opt-out. It also
    applies reset-button default action for app-managed forms with a unit,
    prevent-default `reset` binding, checkbox checked-change default action
    without requiring a click handler, and radio target-value change default
    action for unchecked options. `select_option` models single-value select
    option selection over rendered options and dispatches the target-value
    change path only when the selected value changes. `key_down` submits the nearest
    app-managed form from text-like inputs on Enter unless the keydown policy
    prevents default. Direct `click` remains available as a low-level host test
    primitive.
  - `submit` remains a semantic command for app-managed forms: the native runner
    requires a unit payload descriptor, static prevent-default policy, and an
    enabled target before dispatching the reducer.

The public Roc attr shape, host descriptor stream, render cache, engine sink, and
native host adapter no longer leak separate fixed and named binding payload
shapes or raw listener bits. The remaining split is local host representation:
fixed bindings are still a compact wasm opcode path and simulated-DOM slot path,
while named bindings carry explicit names and encode typed policy to browser
wire bits.

## Design Principles

1. Model browser semantics explicitly.
   The DOM has event phases, propagation, default actions, listener options, and
   target/currentTarget distinctions. The platform should encode those facts
   directly instead of baking assumptions into individual helpers.

2. Keep app state logic typed and DOM-independent.
   Application reducers should receive typed Roc payloads. They should not
   inspect JS event objects or know about DOM layouts.

3. Keep JS a boundary executor.
   JS may execute declared listener policy, filter events, extract declared
   payload leaves, call the WASM host, and apply returned event responses. It
   must not infer application meaning from DOM state.

4. Do not let wire optimizations define the API.
   A fixed `bind_click` opcode can exist as a compression of a canonical event
   descriptor. It must not create a less expressive semantic path.

5. Preserve synchronous event policy.
   `preventDefault`, `stopPropagation`, and `stopImmediatePropagation` must happen
   during the browser event dispatch. Any dynamic decision must be returned from
   the synchronous event dispatch path, not from a task.

6. Make delegation explicit or derived safely.
   Delegated listeners are valid only when their semantics match the requested
   policy. If propagation control, capture, or same-target ordering matters, use
   native listeners.

7. Prefer typed builders over public bit flags.
   Bitmasks are acceptable on the wire. The Roc API and Zig semantic types should
   expose named variants and validation, not unstructured integers.

## Target Roc API

### Types

Illustrative API:

```roc
Event.Type := [Dom(Str), Custom(Str)]

Event.Phase := [Bubble, Capture]

Event.Delivery := [
    Auto,
    Native,
]

# Internal runtime delivery additionally has `Delegated` as an effective delivery
# chosen by `Auto` when every handler is delegation-compatible.

Event.DefaultPolicy := [
    AllowDefault,
    PreventDefault,
]

Event.PropagationPolicy := [
    ContinuePropagation,
    StopPropagation,
    StopImmediatePropagation,
]

Event.Filter := [
    AnyTarget,
    SelfOnly,
    TrustedOnly,
    SelfAndTrusted,
]

Event.Passive := [
    AutoPassive,
    Passive,
    Active,
]

Event.Policy(a) := {
    default : Event.DefaultPolicy,
    propagation : Event.PropagationPolicy,
    passive : Event.Passive,
    once : Bool,
    filter : Event.Filter,
    response : Event.ResponseMode(a),
}

Event.Response := {
    prevent_default : Bool,
    stop_propagation : Bool,
    stop_immediate : Bool,
}

Event.ResponseMode(a) := [
    StaticOnly,
    FromHandler,
]
```

`phase` and `delivery` are listener-level binding fields. `default`,
`propagation`, `passive`, `once`, `filter`, payload, and `response` are
handler-level fields so multiple attributes on the same element/event can compose
without losing per-handler semantics.

Static policy remains orthogonal to event type and payload shape. Dynamic response
intentionally relaxes that orthogonality because `FromHandler` may depend on event
payload and app state.

`FromHandler` is the most powerful form and requires changing the event reducer
shape so the handler can synchronously return both next state and an
`Event.Response`. It should be available for experts, but most code should use
static policy.

Possible handler variants:

```roc
state.on_unit : (model -> model) -> Event.Handler({})
state.on_str : (model, Str -> model) -> Event.Handler(Str)
state.on_bool : (model, Bool -> model) -> Event.Handler(Bool)
state.on_detail : (model, Str -> model) -> Event.Handler(Str)
state.on_key : (model, { key : Str, shift_key : Bool } -> model) -> Event.Handler({ key : Str, shift_key : Bool })
state.on_event : (model, a -> { state : model, response : Event.Response }) -> Event.Handler(a)
```

### Helpers

High-level helpers should be ordinary compositions over the core binding shape,
and should be added only when focused usage proves the sugar is worth carrying:

```roc
Html.on_submit_prevent_default : Event.Handler({}) -> Html.Attr
Html.on_custom : Str, Event.Handler(Str) -> Html.Attr
Html.on_key_down : Event.Handler({ key : Str, shift_key : Bool }) -> Html.Attr

Html.on : Event.Binding(a) -> Html.Attr
```

Bare helpers use the framework default policy. Today, explicit static policy goes
through `Html.on_event`, and explicit native delivery goes through
`Html.on_event_delivery`. Future explicit payload, phase, filter, or richer
delivery builder work should collapse into `Html.on` with the lower-level binding
builder result instead of per-event `_with` helper families.

For common modifier ergonomics, use typed policy values:

```roc
Event.default
Event.prevent_default
Event.stop_propagation
Event.stop_immediate
Event.capture
Event.passive
Event.active
Event.once
Event.self
Event.trusted
Event.native
```

`Event.native` is an explicit semantic escape hatch. Delegation should initially
remain an internal optimization selected by `Auto`; a public `Event.delegated`
should be added only if the runtime can reject incompatible combinations clearly
and users have a demonstrated need to force delegation.

These should be values or builder functions, not raw bit constants.

### Payloads

Event payloads should be typed values that carry both a JS extraction descriptor
and the Roc-side decoder/capability.

```roc
Event.Payload(a)

Event.unit : Event.Payload({})
Event.target_value : Event.Payload(Str)
Event.target_checked : Event.Payload(Bool)
Event.key_shift : Event.Payload({ key : Str, shift_key : Bool })
Event.pointer : Event.Payload({ client_x : F64, client_y : F64, pointer_id : U64, button : I64 })
Event.custom : Boundary.PayloadSchema(a), Event.PathSpec -> Event.Payload(a)
```

Payloads should use the same boundary codec family as subscriptions,
app-specific JS interop, and structured effect results. The event-specific part
is the DOM extraction plan; the cross-boundary encoding should not be unique to
events.

The shared codec exists for the current payload surface. Existing fixed opcodes
can remain as wire-compression mechanisms, but new event payload capabilities
should be framed as leaves/plans over the shared boundary rather than a second
event-only format.

## Static And Dynamic Event Policy

There are two legitimate policy classes.

### Static policy

Static policy is known from the descriptor before the event fires:

```roc
Html.on(Event.bind("submit") |> Event.prevent_default |> Event.handle(state.on_unit(submit)))
Html.on(Event.bind("click") |> Event.stop_propagation |> Event.handle(state.on_unit(close_menu)))
```

JS can apply static `preventDefault` and propagation control before payload
extraction and before calling WASM. That makes policy robust even if payload
extraction fails.

Static policy should cover most cases:

- form submit without navigation;
- nested button inside a draggable card;
- modal/backdrop click isolation;
- menu item click isolation;
- pointer gesture setup;
- disabling browser text selection or drag defaults for custom drag handles.

### Dynamic policy

Dynamic policy is needed when the decision depends on event payload or current
app state:

- prevent a key default only for specific keys;
- stop Escape propagation only when the focused layer handles it;
- prevent pointer defaults only while a drag mode is active;
- allow a form submit to fall through in a deliberately non-managed form;
- conditionally stop a custom event after inspecting `detail`.

There are two possible dynamic designs. The recommended public design is dynamic
response from the handler. A payload-only response function can be added later as
sugar if it is valuable, but it should not be the first public dynamic surface:
it creates a second way to return DOM-response bits while still requiring the
same synchronous host round trip.

#### Dynamic From Handler

The handler returns both next state and response:

```roc
state.on_event(|model, key|
    if key.key == "Escape" && model.menu_open {
        { state: { ..model, menu_open: False }, response: { prevent_default: True, stop_propagation: True, stop_immediate: False } }
    } else {
        { state: model, response: { prevent_default: False, stop_propagation: False, stop_immediate: False } }
    }
)
```

This is the most expressive design. It should exist long term because expert UI
code sometimes needs policy to depend on state. The cost is that the event
dispatch result is no longer just "state changed or not"; it also carries a DOM
event response.

Dynamic response should be available only through explicit `state.on_event`
handlers. Ordinary `on_unit`, `on_str`, `on_bool`, `on_detail`, and `on_key`
handlers should remain simple and should use static policy. This keeps the
common handler surface small and makes synchronous DOM-response behavior visible
at call sites.

### Required Timing

Dynamic policy is only valid for synchronous event handlers. The runtime must:

1. receive browser event;
2. evaluate handler filters;
3. apply static pre-policy for accepted handlers;
4. extract payload;
5. call `roc_ui_event`;
6. receive scalar event-response bits;
7. apply dynamic response immediately;
8. refresh memory views;
9. drain render/effect command buffers once for the event turn.

The response must be applied before the JS listener returns to the browser. A
task result cannot later prevent default behavior or stop propagation for the
already-dispatched event.

## Canonical Event Descriptor

Replace the semantic fixed/named split with one descriptor family.

```zig
pub const EventBindingDesc = struct {
    elem_id: u64,
    event_type: EventType,
    phase: EventPhase,
    requested_delivery: EventDelivery,
    effective_delivery: EventDelivery,
    listener_options: EventListenerOptions,
    handlers: []EventHandlerDesc,
};

pub const EventHandlerDesc = struct {
    event_id: u64,
    binder_token: BinderToken,
    target_node_id: u64,
    policy: EventPolicy,
    payload_descriptor: BoundaryPayloadDescriptor,
    reducer: HostEventReducer,
    response_mode: EventResponseMode,
};
```

A binding is keyed by:

```text
(elem_id, event_type, phase)
```

Delivery is derived from the merged handler set. `Auto` may become delegated only
when every handler is delegation-compatible. Any handler that needs native
semantics makes the effective binding native. Explicit incompatible delivery
requests are validation errors rather than silently changed semantics.

The binding owns an ordered handler chain. Multiple `Html.on(...)` attributes for
the same element and event should be combined into one canonical binding rather
than rejected as duplicates. This gives component composition a defined behavior.
The order is the final rendered attribute-list order after component expansion;
component helpers that add internal handlers should document whether caller
handlers are prepended or appended.

Handler-chain semantics:

- handlers run in descriptor order;
- each handler has its own policy, payload extraction plan, `once` setting,
  filter, and response mode;
- `StopPropagation` affects DOM propagation but does not skip later same-target
  Roc handlers;
- `StopImmediatePropagation` stops later handlers in the chain and maps to
  `event.stopImmediatePropagation()`;
- if any handler requests `preventDefault`, the DOM event is prevented;
- `once` removes that logical handler after one successful invocation; native
  listener `{ once: true }` is only an optimization when it is equivalent for the
  entire binding;
- multiple stateful handlers run in one event turn: state updates are applied in
  descriptor order, response bits are accumulated, and rendering/effect command
  drain happens once after the chain completes and before the JS listener returns.

If batching multiple stateful handlers is too much to implement initially, the
semantic type should still model a handler chain and enforce "only one stateful
handler today" at ingest time. Do not encode "duplicates are impossible" into
descriptor storage.

## JS <-> WASM Event Dispatch

### Browser Listener

JS should store a normalized binding:

```js
{
  elemId,
  eventType,
  phase,
  effectiveDelivery,
  listenerOptions,
  handlers: [
    { eventId, policy, filter, payloadPlan, responseMode, once }
  ]
}
```

On event:

```text
for each handler in chain order:
    if handler filter rejects:
        continue

    apply handler static pre-policy
    payload = extract handler payload plan
    response = roc_ui_event(binding_id or event_id, payload)
    accumulate response policy
    if response.stop_immediate:
        break

apply accumulated response policy
drain command buffer
```

Filters run before policy. A rejected handler does not call Roc and does not apply
that handler's static `preventDefault` or propagation policy. This intentionally
avoids order-dependent modifier semantics.

For multiple handler chains, prefer one `binding_id` crossing into WASM, where
the host owns the handler chain. This centralizes state update ordering, lets
`stopImmediate` terminate the chain without JS knowing handler details, and keeps
all state updates in one event turn.

Calling multiple `event_id`s from JS can be a temporary implementation bridge only
if it preserves the same ordering, response accumulation, and single-drain
semantics.

### Host Export

Current:

```text
roc_ui_event(event_id, payload_kind, payload_ptr, payload_len, bool_value) -> u32 EventResponseBits
```

The active host descriptor table determines the expected payload kind for
`event_id`; JS sends the payload kind it encoded, and the host validates that it
matches before dispatch. Existing static handlers return zero response bits.

Target:

```text
roc_ui_event(
  binding_or_event_id : u32,
  payload_ptr : u32,
  payload_len : u32,
  scalar_bits : u64
) -> u32 EventResponseBits
```

Response bits:

```text
bit 0: prevent_default
bit 1: stop_propagation
bit 2: stop_immediate_propagation
bit 3: handled
bit 4: payload_rejected
```

`handled` is diagnostic and useful for telemetry. `payload_rejected` should only
occur for recoverable extraction/validation modes; malformed protocol data
remains a hard boundary error.

The scalar return is safe to read before refreshing memory views. After the host
call, JS must refresh memory views before reading command buffers because
`roc_alloc` or host work may grow memory.

### Listener Options On The Wire

Wire policy can still be bit-packed:

```text
u32 listener_options:
  capture
  once
  passive
  active_nonpassive

u32 event_policy:
  prevent_default_static
  stop_propagation_static
  stop_immediate_static
  self_only
  trusted_only
  dynamic_response
  force_native
  allow_delegated
```

These are wire fields, not the Roc API. Unknown bits are protocol errors.

### Dynamic Bind Event Record

The target dynamic event command should carry the full canonical policy:

```text
BindEvent:
  u32 elem_id
  u32 binding_id
  u32 event_type_len
  event_type bytes
  u32 phase
  u32 requested_delivery
  u32 effective_delivery
  u32 listener_options
  u32 handler_count
  repeated HandlerRef records

HandlerRef:
  u32 event_id
  u32 event_policy
  u32 event_extraction_plan_len
  event_extraction_plan bytes
  u32 response_mode
```

If the wire keeps fixed opcodes for hot events, they must be generated from this
descriptor and decoded back into the same JS binding shape. The semantic engine
should never have to ask "is this fixed or named?"

## Delivery Strategy

Delivery is a semantic decision with an optimization default.

```roc
Event.Delivery.Auto
Event.Delivery.Native
```

Internally, `Auto` may produce an effective `Delegated` delivery for compatible
bindings.

`Auto` chooses `Native` when any requested feature needs native event-flow
semantics:

- capture phase;
- `stopPropagation`;
- `stopImmediatePropagation`;
- `once`, unless the delegated registry can remove exactly one logical handler;
- `self`, because it means `event.target == event.currentTarget`;
- custom events;
- non-bubbling events;
- shadow DOM/composed-path-sensitive events;
- pointer capture or gesture ownership.

`Auto` may choose `Delegated` for high-volume simple bubble events:

- click without propagation policy;
- input/change where event semantics are known;
- keydown/keyup without stop/default policy;
- pointer move only if measured and policy-compatible.

The runtime should telemetry delivery decisions in debug mode. Initially,
delegation should remain internal: users can request `Native`, but not force
`Delegated`. If a future public `Delegated` option is added, incompatible policy
must fail descriptor validation instead of silently changing semantics.

Current status: `Node.EventBinding` carries a typed delivery request through the
Roc ABI. Host-facing Zig event bindings carry requested/effective delivery and a
native-delivery reason derived before render-cache storage and sink dispatch.
Dynamic `BindEvent` wire records now encode requested/effective delivery and the
reason, and the browser runtime retains them on listener descriptors and in
telemetry; fixed-opcode bindings still derive delivery in JS at decode time as
part of the compression path. This is now the fixed-opcode compression contract:
fixed opcodes are emitted only for canonical fixed bindings, JS normalizes them
into the same listener binding object as dynamic `BindEvent`, and browser
contract tests assert the derived delivery reasons for fixed click and pointer
bindings. All bindings still install native DOM listeners. Policy-required
native reasons are explicit for capture, propagation/default action, `once`,
passive listeners, `self`, and pointer drag setup. Delegated delivery remains
unimplemented and should not become public until the canonical host descriptor
can validate and encode it.

## Payload Boundary

The current event payload design has two layers:

- `Node.EventExtractionPlan.bytes` carries shared schema tags plus DOM-specific
  extraction bytes at the Roc ABI edge;
- the host derives one parsed payload descriptor from those bytes and carries it
  through retained event descriptors, render cache entries, native spec checks,
  dispatch validation, and host sink interfaces;
- Zig now structurally validates the minimal shared schema vocabulary and
  DOM-specific scalar extraction leaves, rejecting empty or nested records before
  mapping to the current compact dispatch descriptors;
- canonical schema bytes are derived from supported extraction plans/descriptors,
  while payload kind remains only the host dispatch container;
- dynamic wasm `BindEvent` records carry event-extraction-plan bytes; JS parses
  the shared schema tags in those bytes, derives payload kind from the schema,
  and retains the parsed extraction descriptor on the listener descriptor;
- the external wasm event ABI validates the JS-sent payload kind against the
  active descriptor;
- fixed-event opcode compression derives canonical payload descriptors from the
  opcode without carrying a payload-accessor word on the wire.
- JS event extraction failures emit `event_payload_error` telemetry, skip reducer
  delivery, and rethrow the deterministic extraction error. Host validation and
  native paths should preserve the same fail-closed model.

The boundary design should keep the remaining fixed/named wire-command split as
compression only while broader public payload APIs grow over the shared codec. A
future generalized schema model may look like:

```zig
pub const BoundaryPayloadSchema = union(enum) {
    unit,
    bool,
    text,
    int,
    float,
    bytes,
    record: []Field,
    list: *BoundaryPayloadSchema,
    optional: *BoundaryPayloadSchema,
};

pub const BoundaryPayloadProducerKind = enum {
    dom_event,
    subscription,
    effect_response,
};

pub const BoundaryPayloadDescriptor = struct {
    schema: BoundaryPayloadSchema,
    producer_kind: BoundaryPayloadProducerKind,
    producer_plan_bytes: []const u8,
};
```

For event bindings, the boundary producer is a DOM extraction plan:

```text
event.key
event.code
event.shiftKey
event.altKey
event.metaKey
event.clientX
event.clientY
event.pointerId
target.value
target.checked
currentTarget.dataset[name]
customEvent.detail[path]
dataTransfer.types
files metadata
```

The shipped schema vocabulary is the shared base for events and the required
base for future subscriptions, app interop, and structured effect responses.
That avoids one event-only binary format and one subscription format later.

The boundary work has shipped for the current payload surface. Future public
event payload or dynamic response capability should build on the same shared
boundary model instead of reviving event-only payload kinds or accessor
descriptors.

The host should still avoid decoding arbitrary Roc layout. It should treat the
boundary payload as bytes or scalar values plus a retained Roc decoder/capability
that constructs the typed Roc payload.

## Interaction With Other WIP Plans

### Wire Protocol

The hybrid wire protocol has shipped: fixed hot records plus versioned dynamic
records for open-ended operations (`src/signals/render_commands.zig`). The
long-term event design agrees with the current semantic rule: all event bindings
first become canonical `EventBinding` descriptors. Fixed event opcodes are
optional wire/cache compression after canonicalization.

Implication:

- version bump the event bind record only when a future payload or dynamic
  response slice changes the encoded descriptor shape;
- keep payload schema/extraction bytes as the semantic field, not a separate
  `payload_kind`;
- keep static policy and delivery data in the structured descriptor;
- add handler chain or binding id data only when a future dynamic-response slice
  or same-event composition canary proves the descriptor shape is needed;
- validate unsupported option combinations in JS and Zig.

### Attribute / Event / Payload Boundary

The shipped boundary made listener options and payload descriptors explicit.
This document extends that: payload and policy should be typed API values and
should use one canonical event descriptor, not fixed helper variants.

Implication:

- keep raw listener option bits out of the public Roc API;
- expose typed policy values/builders;
- keep `Node.Attr.On(EventBinding)` as the public Roc attr shape;
- keep helper APIs as sugar only;
- broaden event payload or dynamic response APIs only over the shared
  boundary-schema vocabulary, never as a second event-only format.

### Controlled Inputs And Forms

Forms require explicit default-action policy. App-managed submit helpers should
make browser navigation prevention visible in the helper name or event policy:

```roc
Html.on_submit_prevent_default(state.on_unit(submit))
```

That helper lowers to static `PreventDefault`. Less common form defaults should
use the named-event policy path, for example `Html.on_event("reset",
Html.event_policy_prevent_default, msg)`.

Input and composition events should use explicit payloads and policies. Avoid
hard-coded runtime behavior such as "all pointer events prevent default." Drag,
selection, form submit, and IME behavior should be described by event policies
and control reconciliation policy.

### JS Integration And Subscriptions

Subscriptions and app-specific JS interop need the same boundary payload codec as
events. Event policy is DOM-specific, but inbound subscription messages and DOM
events should enter the same host scheduling discipline:

- source id/generation validation;
- payload codec validation;
- synchronous state update for DOM events;
- async queued update for subscriptions;
- deterministic cleanup on scope disposal.

The event design should not create an event-only payload representation that C1
has to replace.

### HTTP Effects

HTTP is not directly affected by event propagation, but event handlers often
start tasks. Browser dispatch applies returned DOM response bits before draining
task start commands. That keeps browser event semantics independent of effect
startup.

### Multiple Mounts

Event ids, binding ids, listener registries, delegated document listeners, and
AbortControllers must be mount-scoped. Delegated listeners cannot be a global
singleton that mixes apps unless they route through a mount id and release when
the mount unmounts.

## Compile-Time And Runtime Invariants

These invariants should be enforced as close to the type boundary as possible.

### Roc API invariants

- `passive` and `prevent_default` cannot be combined without an explicit
  `active` override.
- `AutoPassive` plus `prevent_default` resolves to `Active` for browser events
  that may otherwise default to passive listeners, such as `touchstart`,
  `touchmove`, and `wheel`.
- `stop_immediate` implies native delivery unless the delegated implementation
  can exactly reproduce same-target listener ordering.
- `capture` implies native delivery.
- `once` must mean exactly one logical handler invocation, not necessarily one
  native listener invocation.
- `self` means `event.target == event.currentTarget`, not "some equivalent
  component-level target," and therefore implies native delivery.
- event names are non-empty and valid for the chosen event kind.
- custom event payload extraction requires `customEvent.detail` schema.

Roc may not be able to enforce every combination statically, but the public API
should make invalid combinations hard to construct. Zig ingest must reject any
invalid descriptor that reaches it.

### Zig semantic invariants

Introduce typed structs:

```zig
EventType
EventPhase
EventDelivery
EventPolicy
BoundaryPayloadDescriptor
EventBindingKey
EventHandlerChain
```

Avoid passing `u32 options` across engine internals except in the final wire
encoder. Compile-time sink verification should accept an `EventWireBinding` or
typed fields, not a long unstructured argument list.

Required checks:

- descriptor event names are non-empty;
- canonical binding keys are unique per element/event/phase;
- effective delivery is derived from the merged handler set;
- multiple handlers preserve final rendered attribute-list order;
- passive/prevent conflicts are rejected;
- fixed encoding and dynamic encoding round-trip to the same binding shape;
- payload schema matches the retained Roc decoder/capability;
- event ids are dense and mount-scoped;
- stale binding ids are rejected after structural changes;
- listener cleanup always runs on node removal and mount unmount.

### JS runtime invariants

- listener cleanup must use the same options object semantics used at bind time;
- event registry keys include element id, event type, and phase;
- static policy runs before host dispatch for each accepted handler;
- handler filters run before that handler's static policy;
- dynamic response runs immediately after host dispatch and before command drain;
- command drain happens once per event turn after the handler chain completes;
- native delivery is used for policy that cannot be delegated safely;
- `AutoPassive` resolves to an active listener when static or dynamic prevention
  can be requested for default-passive browser events;
- payload extraction reads only declared leaves;
- payload extraction failure is diagnostic and deterministic: JS emits
  `event_payload_error`, skips reducer delivery, and rethrows;
- after any WASM host call, memory views are refreshed before reading buffers;
- delegated document listeners are mount-scoped and removed when unused.

### Native spec runner invariants

The native runner should model event flow, not just event id dispatch.

Add a browser-realistic dispatch primitive:

```text
dispatch_event role:button name:"Add note" type:"click"
real_click role:button name:"Add note"
```

`real_click` should dispatch:

```text
pointerdown
pointerup
click
```

with target, currentTarget, capture, target, and bubble phases. It now honors:

- disabled controls;
- self filters;
- trusted filters for injected user actions;
- prevent default flags for submit;
- stop propagation and stop immediate propagation;
- native vs delegated semantics where the native runner can model them.

`release-planner` keeps a focused nested-control/drag canary: a `real_click` on
the note button nested inside a draggable card increments that card's note count
without starting a drag, proving the pointerdown/pointerup stop-propagation
policy protects the parent card binding.

Remaining event-flow coverage should add default-action simulations only when a
maintained app or focused canary proves the semantic need.

Native specs should still avoid duplicating browser quirks. They should not try
to fully model shadow DOM `composedPath` behavior, default-passive browser
heuristics, or every browser-specific default action. Browser contract tests
should cover JS codec and listener option behavior, including static
default/propagation policy and response-bit timing. Native specs should cover the
engine semantics and app behavior using realistic event flow.

## Current Status And Remaining Candidates

The migration to the canonical event model has shipped for the current public
surface:

- semantic event policy types exist in the Roc ABI, retained host descriptors,
  Zig bindings, and browser wire lowering;
- `EventPolicy` / `event_policy_*` are the public static-policy names,
  `EventDelivery` / `event_delivery_*` are the public delivery-request names,
  and the older `EventOptions` / `event_options_*` aliases have been removed;
- fixed and named events ingest through `Node.Attr.On(EventBinding)`, share one
  retained event descriptor shape, and remain split only for host-local wire/cache
  compression where measurements justify it;
- browser fixed opcodes normalize into the same JS listener binding shape as
  dynamic `BindEvent` records;
- `roc_ui_event` already returns response bits, and the browser listener path
  applies non-zero prevent-default / propagation bits synchronously before the
  event command drain. Unsupported response bits are rejected before command
  drain. Existing Roc handlers still return zero until dynamic response is
  promoted;
- raw public event constructors and listener-option bits have been removed in
  favor of `Html.on_event(name, EventPolicy, msg)` and
  `Html.on_event_delivery(name, EventPolicy, EventDelivery, msg)`;
- `real_click` models browser-style event flow for maintained app semantics, and
  direct `click` remains the low-level unit dispatch primitive.

The remaining event promotion candidates are gated by `wip/NEXT_STEPS.md`:

1. Add dynamic response only through explicit `state.on_event`-style handlers
   when a maintained app or focused canary needs state-dependent response.
2. Add handler chains only when a maintained app or focused canary proves
   same-event composition pressure, or when the promoted dynamic-response
   implementation requires them. The target is one event turn, ordered state
   updates, accumulated response bits, and one render/effect drain. An
   intermediate implementation may reject multiple stateful handlers after
   canonicalization while preserving the chain descriptor.
3. Treat delegated delivery as an internal `Auto` optimization until measurements
   prove listener count is a real bottleneck and policy-compatible delegation can
   be validated clearly.

Promotion triggers:

- Dynamic response: name one maintained app or focused canary that needs
  state-dependent DOM response beyond the current static `EventPolicy`.
- Handler chains: name one maintained app or focused canary with same-event
  composition pressure, or point to the promoted dynamic-response slice that
  requires ordered state updates and accumulated response bits.
- Delegated delivery: add current measurement showing listener count is the
  bottleneck, plus the policy-compatible semantic checks for delegated dispatch.

Future `Html.on` or typed payload helper work must lower to the same canonical
descriptor shape and must not introduce parallel `_with` event families or
event-specific payload formats.

## Design Tradeoffs

### Static policy only vs dynamic response

Static policy is easier and should be the default. It is enough for many UI
boundaries and can be applied before any host call.

Dynamic response is necessary for expert UI. Without it, the platform forces
users into overly broad static policies or into JS escape hatches. The cost is a
new synchronous return value from event dispatch and a more expressive handler
shape.

Decision: support both. Static first, dynamic as the expert layer. Dynamic
response should be opt-in through explicit `state.on_event` handlers, not part of
every ordinary handler shape.

### Native listeners vs delegation

Delegation can reduce listener count for large lists, but it changes the control
surface for propagation-sensitive events. Solid's documentation calls out this
exact trap.

Decision: make delivery a listener-level binding decision derived from handler
policy. `Auto` may delegate only when every handler is compatible. Expose
`native` as the public escape hatch first; keep forced `delegated` internal until
there is a clear use case and validation story.

### One handler per event vs handler chains

One handler per element/event is simpler but composes poorly. Component internals
and user-provided callbacks naturally want to stack behavior.

Decision: the canonical model should support ordered handler chains. The full
semantics are one event turn, ordered state updates, accumulated response bits,
and one render/effect drain. If the first implementation cannot batch multiple
stateful handlers safely, reject multiple stateful handlers after canonicalization
while preserving the target shape.

### Payload accessors vs payload schemas

Small accessor enums are fast but do not scale. A full schema/extraction plan is
more complex but solves keyboard, pointer, clipboard, drag/drop, files, custom
events, subscriptions, and interop with one concept.

Decision: shared schema/extraction bytes are the semantic model and are
implemented for the current payload canaries. Broader event payload APIs should
extend that model. Accessor enums can remain as compatibility and wire
compression for common schemas, but they should not become a second public
payload system.

### Exposing DOM Event vs typed payloads

Exposing the DOM event object is flexible in JS frameworks, but it breaks the
Signals boundary: JS objects cannot cross into Roc, and app code should not
depend on browser object shape.

Decision: do not expose DOM events. Expose typed payload descriptors and dynamic
event responses.

## Concrete App Outcomes

The release planner note button should be expressible without raw bits:

```roc
note_button =
    Html.button_attrs(
        label,
        [
            Html.on(
                Event.bind("pointerdown")
                    |> Event.stop_propagation
                    |> Event.handle(board_state.on_unit(noop))
            ),
            Html.on(
                Event.bind("pointerup")
                    |> Event.stop_propagation
                    |> Event.handle(board_state.on_unit(noop))
            ),
        ],
        board_state.on_unit(add_note),
    )
```

The better app design is a drag handle:

```roc
Html.button_attrs(
    "Drag",
    [
        Html.on(
            Event.bind("pointerdown")
                |> Event.prevent_default
                |> Event.stop_propagation
                |> Event.handle(board_state.on_unit(start_drag))
        ),
    ],
    board_state.on_unit(noop),
)
```

The card itself should not become a drag source for every nested control unless
the product really wants that interaction.

Forms become clear:

```roc
Html.form(
    [
        Html.on(
            Event.bind("submit")
                |> Event.prevent_default
                |> Event.handle(state.on_unit(submit))
        ),
    ],
    fields,
)
```

Keyboard shortcuts become precise:

```roc
Html.on(
    Event.bind("keydown")
        |> Event.native
        |> Event.payload(Event.key_shift)
        |> Event.dynamic_response
        |> Event.handle(state.on_event(handle_key))
)
```

## Open Questions

1. Which additional shared schema leaves or containers, beyond the current schema
   tags embedded in `EventExtractionPlan` bytes, are needed by events,
   subscriptions, app interop, or structured effects? This should be answered by
   a maintained app or focused canary before adding broad event payload APIs.
2. How much of payload/schema compatibility can Roc encode in types before Zig
   ingest validation?
3. Should forced public `Event.Delivery.Delegated` ever exist, or should
   delegation remain a measured internal `Auto` optimization with only `native`
   as an explicit public escape hatch?

Resolved decisions from this document:

- App-managed form submit is explicit in helper naming:
  `Html.on_submit_prevent_default` carries static prevent-default policy. Generic
  app-managed reset uses `Html.on_event("reset", Html.event_policy_prevent_default, ...)`.
- Dynamic response is returned only from explicit `state.on_event` handlers.
- If same-event composition is promoted, multiple stateful handlers should batch
  into one event turn with one render/effect drain; until then they may be
  rejected after canonicalization.
- Forced public delegation is deferred; expose `native` first.

## Recommended Target

The long-term model should be:

- one canonical event descriptor in the engine;
- typed Roc `Event.Policy` and `Event.Payload(a)` values;
- high-level helpers as sugar over canonical bindings;
- handler-level policy, payload, filter, `once`, and response mode;
- no public raw listener bitmasks;
- no semantic split between fixed and named events;
- JS listener registry built from canonical event bindings;
- native delivery whenever propagation semantics require it;
- synchronous `roc_ui_event -> EventResponseBits`;
- shared boundary payload schemas across events, subscriptions, and interop as the
  prerequisite for broad event payload and dynamic-response work;
- native spec runner support for browser-realistic event flow.

This gives expert frontend engineers real control without blowing out the helper
API surface. It also turns the release planner bug from a surprising platform
failure into a normal, testable event-flow case.
