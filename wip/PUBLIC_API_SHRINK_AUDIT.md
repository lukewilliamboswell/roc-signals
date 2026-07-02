# Public API Shrink Audit

Working classification for the platform boundary modules around `Node`. This
exists to keep the next API slices pointed at one core model plus small sugar,
instead of preserving every historical route as a design input.

## Keep As Core

- `Html.attr`, `Html.attr_s`, `Html.bool_attr`, `Html.bool_attr_s`: the general
  attribute surface. Fixed attributes should lower to the same internal model
  where possible, with host compression remaining an implementation detail.
- `Html.on_event : Str, EventPolicy, Node.Msg -> Node.Attr`: the canonical
  named-event escape hatch. It takes typed policy data and lowers to the current
  browser command bitset only at the wire edge.
- `Html.on_event_delivery : Str, EventPolicy, EventDelivery, Node.Msg -> Node.Attr`:
  the same named-event escape hatch when the caller needs an explicit delivery
  request. Keep this as the single low-level delivery entry point rather than
  adding event-specific helper variants.
- `Ui.State.on_unit`, `Ui.State.on_str`, `Ui.State.on_bool`, `Ui.State.on_key`:
  typed reducer constructors. They select explicit boundary payload/extraction
  descriptors through file-local `Ui` message construction; app-facing message
  construction no longer exposes raw event payload constants, reusable boundary
  payload values, or public `Node.event_msg_*` constructors.
- `Node.Msg`: reducer message values. Apps pass messages to event helpers;
  low-level public construction helpers have been removed from `Node`.
- `Node.EventPolicy`: typed listener policy data carried through
  `Node.EventBinding`. Static policy now includes default and propagation
  controls, capture/passive/once, and `self`/`trusted` filters without adding
  event-specific helper families. Public policy value sugar lives in `Html`;
  `Node` only exports the policy shape.
- `Node.EventDelivery`: typed listener delivery request carried through
  `Node.EventBinding`. `Html` defaults it to Auto and exposes Auto/Native values
  for the low-level named-event path; the host derives the effective native
  delivery decision before sink dispatch, and the browser command wire still
  derives matching telemetry from existing command fields until canonical event
  commands encode delivery directly.
- `Node.BoundarySchema` and `Node.EventExtractionPlan`: typed Roc-side ABI
  descriptor wrappers carried inside `Node.Msg`. `Ui.State` selects those
  descriptors through file-local helpers; app-facing message construction no
  longer exposes a generic boundary payload container or constructor.
- `Node.TextField` and `Node.BoolField`: typed Roc-side attribute field
  descriptors. `Node.Attr.StaticText`/`SignalText` and
  `Node.Attr.StaticBool`/`SignalBool` now require these wrappers instead of raw
  field ids. Built-in field ids are file-local `Html` lowering details.
- `Node.EventBinding`: canonical Roc-side event binding descriptor carried by
  `Node.Attr.On(EventBinding)`. Fixed bindings take typed
  `Node.FixedEventKind` values, while named bindings take typed
  `Node.EventPolicy` and `Node.EventDelivery`; file-local `Html` lowering
  constructs those records and the host still recognizes fixed bindings as a
  compact execution path.

## Keep As Sugar

- Fixed event helpers: `Html.on_pointer_down`, `Html.on_pointer_up`,
  `Html.on_pointer_enter`, `Html.on_pointer_leave`, `Html.on_key_down`,
  `Html.on_focus`, `Html.on_blur`, `Html.on_change`,
  `Html.on_composition_start`, `Html.on_composition_end`. These should stay only
  while they lower to the canonical event descriptor.
- Hot fixed event helpers route through file-local `Html` binding constructors
  and `Node.Attr.On(EventBinding)`. The host still lowers fixed bindings to the
  compact fixed-event execution path because moving pointer/click/input/check
  helpers to dynamic named events raised `stream_nodes_scanned_events` from 2 to
  33 in the `release-planner` structural update canary.
- Specialized form helpers such as `Html.on_submit_prevent_default` and
  `Html.aria_describedby`: keep when they hide a common policy or naming detail
  without introducing a separate semantic path.
- Fixed field helpers such as `Html.class_attr` and element constructors such as
  `Html.button`/`Html.text_input`: keep as ergonomic sugar over the same
  descriptor vocabulary.

## Temporary Compatibility

- Listener option bits are no longer public Roc constants and are no longer part
  of the Roc `EventBinding` ABI shape. `Node` no longer exports policy constants
  or event binding constructors; `Html` passes typed `EventPolicy` and
  `EventDelivery` data through `Node.EventBinding`, and the wasm host lowers
  policy to listener-option bits only when writing browser commands. Browser and
  native runner dispatch apply
  `self`/`trusted` filters before reducer delivery. Browser contract coverage
  now asserts static prevent-default, stop-propagation, stop-immediate, listener
  option forwarding, and response-bit timing without adding helper families.
- Boundary schema and event extraction raw scalar ids are no longer public Roc
  constants. The older generic `Node.event_msg(BoundaryPayload, ...)`
  constructor, public `Node.event_msg_*` constructors, and temporary
  `Node.compat_event_msg_from_payload` / `Node.CompatBoundaryPayload` container
  have been removed. File-local `Ui` `BoundarySchema` / `EventExtractionPlan`
  byte values remain as temporary Roc-side descriptor storage because
  constructing the larger descriptor byte lists directly inside `State.on_key`
  regressed wasm mounting. Zig derives a parsed
  `boundary.BoundaryPayloadDescriptor` from the schema/extraction bytes carried
  inside `Node.Msg` during ABI ingest.
  `src/signals/boundary.zig` structurally validates the minimal shared schema
  vocabulary (`unit`, `text`, `bool`, non-empty records of primitive leaves) and
  the DOM-specific extraction-plan bytes, rejecting empty or nested records while
  native dispatch still supports only the current compact descriptor canaries.
  Canonical schema bytes are derived from the supported extraction plan or parsed
  descriptor, not from the generic payload container id. Descriptor stream
  entries, render-cache bindings, native dispatch validation, the native
  simulated DOM, native specs, and host sink interfaces now carry the parsed
  `BoundaryPayloadDescriptor` as one value. Browser dynamic `BindEvent` records
  now carry both boundary schema bytes and event extraction-plan bytes, validate
  that they match,
  reject malformed record names, malformed DOM extraction source/leaf bytes, and
  impossible source/leaf pairs, and derive payload kind from the boundary schema.
  The wasm command encoder takes the parsed
  `boundary.BoundaryPayloadDescriptor` and serializes those bytes only at the
  browser wire edge. The browser runtime keeps the parsed boundary schema
  together with the event extraction plan in retained listener descriptors and
  telemetry.
- Browser event extraction failures now emit `event_payload_error` telemetry,
  skip reducer delivery, and rethrow the deterministic extraction error. Keep
  validation failures fail-closed when extending the boundary vocabulary.
- Fixed event kind ids are no longer public Roc constants. They are still the
  host wire representation behind `Node.FixedEventKind`, with built-in fixed
  kinds selected by file-local `Html` lowering data.
- Text and bool attribute field ids are no longer public Roc constants. They are
  still the host wire representation behind `Node.TextField` and
  `Node.BoolField`, with built-in fields selected by file-local `Html` lowering
  data.
- Public signatures still name `Node.Msg`, `Node.Attr`, `Node.Cmd`, and
  `Node.Cleanup` directly. A trial app-facing alias pass (`Html.Msg`, `Ui.Msg`,
  `Signal.Cmd` / `Signal.Cleanup`) was reverted because the native first build
  regressed into high CPU / no completion, and module-level qualified aliases
  were not exposed reliably across `Signal` and `Ui`. Do not use alias signatures
  as the next shrink route until that compiler/codegen behavior is understood.
- The host descriptor stream now stores fixed and named event bindings in one
  table after ingesting `Node.Attr.On(EventBinding)`. Fixed opcodes may remain as
  wire/cache compression only; the public Roc attr shape no longer exposes
  separate `OnEvent`/`OnNamedEvent` constructors.
- Native specs now dispatch click/input/check/pointer commands through either
  fixed bindings or canonical named bindings. This keeps the test surface ready
  for the eventual internal event unification without forcing the slower named
  path onto maintained apps today.

## Removal / Replacement Targets

- Keep collapsing fixed/named semantics while preserving fixed-event compression
  until measurements say it can be removed. The render-cache, engine sink, JS
  decoded-command/listener path, native host adapter, and simulated-DOM binding
  shape now share one event binding command/payload model; the remaining split is
  host-local fixed opcode/slot compression vs named records with explicit
  names and browser listener-policy bits encoded from typed `EventPolicy`.
- Remove the remaining file-local `Ui` `boundary_schema_*` /
  `event_extraction_*` descriptor byte values once the wasm key-shift descriptor
  allocation regression has a smaller safe fix.
- Do not add more `_with` event helper families. Add a typed option/payload
  value when sugar cannot express a real maintained canary.
