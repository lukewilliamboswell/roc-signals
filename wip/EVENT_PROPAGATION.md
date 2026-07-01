# Event Propagation And Listener Policy

This is the long-term target design for DOM event handling in Signals after the
shared boundary model is settled. It is not a compatibility plan for the current
fixed/named event split, and it should not grow a duplicate event-specific payload
or policy surface. The current implementation can migrate toward this
incrementally, but the design below should be judged against the requirements of
expert frontend work and the goal of a smaller public API.

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

Html.on : Event.Binding(a) -> Node.Attr
```

Most application code should use helpers:

```roc
Html.on_click(state.on_unit(save))
Html.on_submit_with(Event.prevent_default, state.on_unit(submit))
Html.on_key_down_with(Event.default |> Event.payload(Event.key), state.on_value(handle_key))
Html.on_pointer_down_with(Event.stop_propagation, state.on_unit(start_drag))
```

The lower-level API should remain available:

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

## Minimum Viable Slice

The long-term design below is intentionally broader than the first implementation,
but event propagation should not be the next API-expansion wedge. The first step is
shared boundary consolidation: one small payload/descriptor model that events,
subscriptions, app interop, and structured effects can reuse.

After that boundary exists, the first shippable event slice should solve the
release-planner class of bugs with minimal public surface:

1. Canonicalize fixed `OnEvent` and dynamic `OnNamedEvent` attributes into one
   internal event descriptor family. Existing APIs may lower through compatibility
   shims, but the semantic model should have one path.
2. Introduce typed semantic event policy in Zig and treat current raw option bits as
   ingest/encoding compatibility only.
3. Add or keep only the smallest Roc API needed to express static policy over the
   canonical descriptor. Do not add parallel helper families unless they replace an
   older surface or clearly lower to the core API.
4. Change `roc_ui_event` to return event-response bits, initially always zero for
   existing static handlers, so dynamic response can be added later without another
   ABI break.
5. Normalize fixed and named bindings to the same JS listener object and use native
   listeners whenever requested policy requires native event-flow semantics.
6. Add native spec-runner event-flow dispatch, especially `real_click` as
   `pointerdown -> pointerup -> click` with bubbling and propagation policy.

Dynamic handler responses and fully general multiple-stateful-handler batching are
important long-term work, but they should not be prerequisites for the static
policy slice. Event-specific payload formats should not be added; event payloads
must use the shared boundary model once it exists.

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
  - `Attr` has `OnEvent({ kind, msg })` for fixed event kinds and
    `OnNamedEvent({ name, options, msg })` for dynamic events.
  - listener options are exposed as `U64` bit constants.
- `platform/Html.roc`
  - fixed helpers such as `on_pointer_down` use `OnEvent`, which cannot carry
    listener policy.
  - `on_event` accepts raw option bits and is currently the escape hatch.
- `src/signals/descriptor_stream.zig`
  - stores `EventDesc` and `NamedEventDesc` separately.
- `src/signals/render_cache.zig`
  - stores fixed event bindings separately from named event bindings.
- `src/wasm_host.zig`
  - fixed events emit fixed opcodes; named events emit dynamic `BindEvent`
    records with options and payload descriptors.
- `www/static/signals.mjs`
  - fixed events bind directly with `addEventListener(event, listener)`.
  - named events parse listener option bits, apply static prevent/stop policy,
    and decode payload descriptors.
- `src/spec/spec_runner.zig`
  - semantic actions dispatch directly to the bound event id and do not yet model
    full browser event flow for click/pointer interactions.

The current dynamic named-event path is much closer to the target model than the
fixed event-kind path. The problem is that the platform leaks the distinction.
Long term, `OnEvent` vs `OnNamedEvent` should disappear from the semantic model.

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
state.on_value : (model, a -> model) -> Event.Handler(a)
state.on_event : (model, a -> { state : model, response : Event.Response }) -> Event.Handler(a)
```

### Helpers

High-level helpers should be ordinary compositions over the core binding shape:

```roc
Html.on_click : Event.Handler({}) -> Node.Attr
Html.on_click_with : Event.Policy({}), Event.Handler({}) -> Node.Attr

Html.on_input : Event.Handler(Str) -> Node.Attr
Html.on_input_with : Event.Policy(Str), Event.Handler(Str) -> Node.Attr

Html.on_submit : Event.Handler({}) -> Node.Attr
Html.on_submit_with : Event.Policy({}), Event.Handler({}) -> Node.Attr
Html.on_submit_prevent_default : Event.Handler({}) -> Node.Attr

Html.on : Event.Binding(a) -> Node.Attr
```

Bare helpers use the framework default policy. `_with` helpers accept explicit
policy values. `Html.on` accepts the full lower-level binding builder result.

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
Event.key : Event.Payload({ key : Str, shift_key : Bool })
Event.pointer : Event.Payload({ client_x : F64, client_y : F64, pointer_id : U64, button : I64 })
Event.custom : Boundary.Schema(a), Event.PathSpec -> Event.Payload(a)
```

Payloads should use the same boundary codec family as subscriptions,
app-specific JS interop, and structured effect results. The event-specific part
is the DOM extraction plan; the cross-boundary encoding should not be unique to
events.

The shared codec should be implemented before broadening the event API. Existing
payload accessors can remain as compatibility and wire-compression mechanisms,
but new event payload capabilities should be framed as leaves/plans over the
shared boundary rather than a second event-only format.

## Static And Dynamic Event Policy

There are two legitimate policy classes.

### Static policy

Static policy is known from the descriptor before the event fires:

```roc
Html.on_submit_with(Event.prevent_default, state.on_unit(submit))
Html.on_click_with(Event.stop_propagation, state.on_unit(close_menu))
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
handlers. Ordinary `on_unit` and `on_value` handlers should remain simple and
should use static policy. This keeps the common handler surface small and makes
synchronous DOM-response behavior visible at call sites.

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
    payload: EventPayloadPlan,
    payload_codec: BoundaryCodec,
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
roc_ui_event(event_id, payload_kind, payload_ptr, payload_len, bool_value) -> void
```

Target:

```text
roc_ui_event(
  binding_or_event_id : u32,
  payload_format : u32,
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
  u32 payload_schema_len
  payload_schema bytes
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

## Payload Boundary

The current event payload design has two layers:

- `payload_kind` tells the host which HostValue shape to construct;
- `payload_accessor` or dynamic payload descriptor tells JS what to read.

The boundary design should replace this with a shared boundary codec before event
propagation grows broader public payload APIs:

```zig
pub const BoundarySchema = union(enum) {
    unit,
    bool,
    text,
    int,
    float,
    bytes,
    record: []Field,
    list: *BoundarySchema,
    optional: *BoundarySchema,
};

pub const EventPayloadPlan = struct {
    schema: BoundarySchema,
    extraction: EventExtractionPlan,
};
```

The extraction plan is event-specific:

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

The schema should eventually be shared by events, subscriptions, app interop, and
structured effect responses. This avoids one event-only binary format and one
subscription format later.

This boundary work should be prioritized before broad event-policy API work. The
first event-policy implementation may keep the current event payload kinds and
accessor descriptors as compatibility internals, but new public event capability
should be expressed through the shared boundary model.

The host should still avoid decoding arbitrary Roc layout. It should treat the
boundary payload as bytes or scalar values plus a retained Roc decoder/capability
that constructs the typed Roc payload.

## Interaction With Other WIP Plans

### Wire Protocol

`wip/WIRE_PROTOCOL_DESIGN_PREP.md` already recommends a hybrid wire: fixed hot
records plus dynamic records for open-ended operations. The long-term event
design agrees with the dynamic record direction but changes the semantic rule:
all event bindings should first become canonical dynamic descriptors. Fixed
event opcodes are optional compression after canonicalization.

Implication:

- version bump the event bind record when policy becomes structured;
- add a `payload_schema` field, not only `payload_kind`;
- include phase and delivery;
- include handler chain or binding id;
- validate unsupported option combinations in JS and Zig.

### Attribute / Event / Payload Boundary

`wip/ATTRIBUTE_EVENT_PAYLOAD_BOUNDARY_DESIGN_PREP.md` correctly identified that
listener options and payload descriptors must be explicit. This document extends
that: payload and policy should be typed API values and should use one canonical
event descriptor, not fixed helper variants.

Implication:

- retire raw public `U64` listener option bits;
- expose typed policy builders;
- replace `OnEvent` / `OnNamedEvent` with `On(Event.Binding)`;
- keep helper APIs as sugar only;
- implement the shared `BoundarySchema` before broadening event payload or dynamic
  response APIs.

### Controlled Inputs And Forms

Forms require default-action policy. `submit` should be app-managed by default
in form helpers:

```roc
Html.form_on_submit(state.on_unit(submit))
```

should compile to `PreventDefault` unless the helper name or policy says
otherwise.

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
start tasks. The event dispatch should return DOM response bits before JS drains
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
EventPayloadPlan
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
- payload extraction failure is diagnostic and deterministic;
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

with target, currentTarget, capture, target, and bubble phases. It should honor:

- disabled controls;
- self filters;
- trusted filters, probably always trusted in user actions;
- prevent default flags for submit and navigation simulations;
- stop propagation and stop immediate propagation;
- native vs delegated semantics where the native runner can model them;
- form submit default behavior where relevant.

Native specs should still avoid duplicating browser quirks. They should not try
to fully model shadow DOM `composedPath` behavior, default-passive browser
heuristics, or every browser-specific default action. Browser contract tests
should cover JS codec and listener option behavior. Native specs should cover the
engine semantics and app behavior using realistic event flow.

## Refactor Plan Toward The Target

This sequence is implementation guidance, not a compromise on the target model.

1. Add semantic event policy types in Zig.
   Keep wire bits as an encoder detail. Convert current named event `options`
   into `EventPolicy` at descriptor ingest.

2. Add typed Roc policy builders.
   Keep old constants temporarily, but stop teaching examples to use raw bits.
   Public docs should describe `Event.Policy` and `_with` helpers.

3. Unify fixed and named event descriptors internally.
   `OnEvent` and `OnNamedEvent` can still exist at the ABI edge while ingesting
   into one `EventBindingDesc`. Handler-level policy and payload should be
   represented even if the first implementation permits only one stateful handler
   per binding.

4. Move fixed event bindings onto the same JS binding object.
   `bind_click` may still be emitted, but JS should normalize it into the same
   `EventBinding` structure used by dynamic `BindEvent`.

5. Change `roc_ui_event` to return response bits.
   Initially return zero for existing handlers. Then add dynamic response
   handlers.

6. Replace public raw event APIs.
   Introduce `Html.on`, `Html.on_*_with`, and typed payload helpers. Deprecate
   public `Html.on_event(name, U64, msg)`.

7. Add native event-flow dispatch.
   Replace direct `click` assumptions in specs that need browser-realistic
   behavior. Keep direct dispatch only as a low-level host test primitive.

8. Introduce handler chains.
   The long-term rule is one event turn with ordered state updates and one command
   drain. If that cannot be implemented immediately, reject multiple stateful
   handlers after canonicalization while preserving the chain descriptor.

9. Retire semantic fixed/named split.
   Fixed wire ops can remain only if they are provably equivalent compression of
   canonical descriptors.

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

Decision: payload schemas are the semantic model and should be implemented before
broad event API expansion. Accessor enums can remain as compatibility and wire
compression for common schemas, but they should not become a second public payload
system.

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
            Html.on_pointer_down_with(Event.stop_propagation, board_state.on_unit(noop)),
            Html.on_pointer_up_with(Event.stop_propagation, board_state.on_unit(noop)),
        ],
        board_state.on_unit(add_note),
    )
```

The better app design is a drag handle:

```roc
Html.button_attrs(
    "Drag",
    [Html.on_pointer_down_with(Event.prevent_default |> Event.stop_propagation, board_state.on_unit(start_drag))],
    board_state.on_unit(noop),
)
```

The card itself should not become a drag source for every nested control unless
the product really wants that interaction.

Forms become clear:

```roc
Html.form(
    [Html.on_submit_with(Event.prevent_default, state.on_unit(submit))],
    fields,
)
```

Keyboard shortcuts become precise:

```roc
Html.on_key_down_with(
    Event.default
        |> Event.native
        |> Event.payload(Event.key)
        |> Event.dynamic_response,
    state.on_event(handle_key)
)
```

## Open Questions

1. Should `prevent_default` be static by default for app-managed submit helpers,
   or should the helper name always make it explicit?
2. What is the first shared `BoundarySchema` format that can serve events,
   subscriptions, app interop, and structured effects without overbuilding? This
   should be answered before adding broad event payload APIs.
3. How much of payload/schema compatibility can Roc encode in types before Zig
   ingest validation?
4. Do we eventually want public `Event.Delivery.Delegated`, or should delegation
   permanently remain an internal optimization with only `native` as an explicit
   escape hatch?

Resolved decisions from this document:

- Dynamic response is returned only from explicit `state.on_event` handlers.
- Multiple stateful handlers should eventually batch into one event turn with one
  render/effect drain; until then they may be rejected after canonicalization.
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
