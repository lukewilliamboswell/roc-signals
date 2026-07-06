# Public API Shrink Audit

Working classification for the platform boundary modules around `Node`. This
exists to keep the next API slices pointed at one core model plus small sugar,
instead of preserving every historical route as a design input.
`platform/main.roc` exposes app-facing modules `Elem`, `Signal`, `Html`, `Ui`,
and `Http`; it does not expose `Node` as an app-importable module. `Node.*`
entries below classify the current internal descriptor types that still appear
in exposed signatures or host-facing ABI shape, so future public work can shrink
or alias those leaks rather than treating them as app-facing design centers.

## Validation

For audit-only edits that just update classification notes or cross-links, run
`git diff --check` and `zig build run-check-tidy`.

When an audit edit accompanies platform Roc, ABI, docs, example, or host behavior
changes, also run the focused gate from `wip/NEXT_STEPS.md` for that surface.
Public platform surface changes should include `python3 scripts/test.py
roc-check`; behavior or host changes need the focused native/browser/wasm gate
that proves the slice before the end-to-end repository gate.

## Keep As Core

- `Elem`: the app-facing UI descriptor tree returned by `main` and produced by
  `Html` / `Ui` helpers. Keep it as the pure descriptor boundary the host walks;
  raw descriptor variants are ABI shape, not a reason to add public ids,
  host-owned handles, or parallel constructor families.
- `Html.attr`, `Html.attr_s`, `Html.attr_maybe_s`, `Html.bool_attr`,
  `Html.bool_attr_s`: the general attribute surface. Fixed attributes should
  lower to the same internal model where possible, with host compression
  remaining an implementation detail. `attr_maybe_s` is the explicit absence
  path for signal-backed custom text attrs: `None` clears, `Some(Str)` sets.
- `Html.on_event : Str, EventPolicy, Node.Msg -> Node.Attr`: the canonical
  named-event escape hatch. It takes typed policy data and lowers to the current
  browser command bitset only at the wire edge.
- `Html.on_event_delivery : Str, EventPolicy, EventDelivery, Node.Msg -> Node.Attr`:
  the same named-event escape hatch when the caller needs an explicit delivery
  request such as `Html.event_delivery_native`. Keep this as the single
  low-level delivery entry point rather than adding event-specific helper
  variants.
- `Ui.state`, `Ui.State.signal`, `Ui.component`, `Ui.when`, and `Ui.each_str`:
  the current structural identity surface. They introduce explicit state,
  component, branch, and keyed-row scopes while keeping identity in host-owned
  construction-order and keyed scope tables instead of public ids.
- `Ui.State.on_unit`, `Ui.State.on_str`, `Ui.State.on_bool`,
  `Ui.State.on_detail`, and `Ui.State.on_key`: typed reducer constructors.
  `Ui.KeyPayload` is the app-facing keyboard payload alias for
  `{ key : Str, shift_key : Bool }`. The reducers select explicit boundary
  payload/extraction descriptors through the unexposed internal `EventExtraction`
  platform module; app-facing message construction no longer exposes raw event
  payload constants, reusable boundary payload values, or public
  `Node.event_msg_*` constructors.
- `Node.Msg`: reducer message values. Apps pass messages to event helpers;
  low-level public construction helpers have been removed from `Node`.
- `Node.EventPolicy`: typed listener policy data carried through
  `Node.EventBinding`. Static policy now includes default and propagation
  controls, capture/passive/once, and `self`/`trusted` filters without adding
  event-specific helper families. `Html` exposes the public `EventPolicy` alias
  plus the common policy constants; rarer policy combinations use the record
  shape instead of new helper families. `Node` defines the policy shape consumed
  by the `Html` aliases.
- `Node.EventDelivery`: typed listener delivery request carried through
  `Node.EventBinding`. `Html` defaults it to `Html.event_delivery_auto` and
  exposes `Html.event_delivery_auto` / `Html.event_delivery_native` for the
  low-level named-event path; the host derives the effective native delivery
  decision before sink dispatch. Dynamic `BindEvent` wire records encode
  requested/effective delivery and the derivation reason; fixed-opcode
  bindings still derive delivery in JS at decode time as part of the
  compression path.
- `Node.EventExtractionPlan`: typed Roc-side ABI descriptor wrapper carried
  inside `Node.Msg`. `Ui.State` selects descriptors through the unexposed
  internal `EventExtraction` platform module; app-facing message construction no
  longer exposes a generic boundary payload container or constructor.
- `Node.TextField` and `Node.BoolField`: typed Roc-side attribute field
  descriptors. `Node.Attr.StaticText`/`SignalText`/`TextOptionalSignal` and
  `Node.Attr.StaticBool`/`SignalBool` now require these wrappers instead of raw
  field ids. Built-in field ids are file-local `Html` lowering details.
- `Node.EventBinding`: canonical Roc-side event binding descriptor carried by
  `Node.Attr.On(EventBinding)`. Fixed bindings take typed
  `Node.FixedEventKind` values, while named bindings take typed
  `Node.EventPolicy` and `Node.EventDelivery`; file-local `Html` lowering
  constructs those records and the host still recognizes fixed bindings as a
  compact execution path.
- `Signal.const`, `Signal.map`, `Signal.map2`, `Signal.combine`,
  `Signal.Task`, `Signal.TaskStatus`, `Signal.from_task`, `Signal.fold_task`,
  `Signal.start_str`, `Signal.interval`, `Ui.on_change`,
  `Ui.on_change_initial`, `Ui.on_mount`, `Ui.on_cleanup`, `Node.Cmd`, and
  `Node.Cleanup`: the current structural signal/effect/lifecycle surface. Keep
  the model descriptor-first: Roc declares sources, task status, commands, and
  cleanup descriptors; the host owns ids, request tokens, interval handles, and
  disposal. `Node.Cmd` and `Node.Cleanup` still appear in signatures only
  because the app-facing alias pass was backed out; do not use that naming leak
  as a reason to add public id or
  lifecycle-token APIs. Keep `Signal.map2` as the applicative primitive Roc
  record-builder syntax needs, but prefer `{ field: signal, ... }.Signal` for
  named multi-signal joins instead of adding `Signal.map3`, `Signal.map4`, or
  higher-arity helper families.
- `Http.request_task`, `Http.start`, `Http.HttpError`, `Http.method_*`, and the
  package-aligned request/response builder/accessor wrappers in `Http`: the
  shipped HTTP task surface. Keep it pinned to `roc-lang/http` request/response
  values plus Signals-owned transport errors and explicit request/response
  envelopes; do not introduce a second Signals-only request model.
- `Browser.Location`, `Browser.Visibility`, `Browser.StorageText`,
  `Browser.location`, `Browser.visibility`, `Browser.online`,
  `Browser.local_storage_text`, `Browser.session_storage_text`,
  `Browser.push_state`, `Browser.replace_state`, `Browser.set_title`,
  `Browser.set_local_storage_text`, `Browser.set_session_storage_text`,
  `Browser.remove_local_storage`, and `Browser.remove_session_storage`: the
  shipped browser-environment surface. Keep route parsing, storage key
  namespacing, serialization, and domain validation in app/package code. Do not
  widen this into a router DSL, whole-store snapshot, raw browser API catalog,
  or public generic `Sub` surface without a maintained app or focused canary.

## Keep As Sugar

- Fixed event helpers: `Html.on_pointer_down`, `Html.on_pointer_up`,
  `Html.on_pointer_enter`, `Html.on_pointer_leave`, `Html.on_key_down`,
  `Html.on_focus`, `Html.on_blur`, `Html.on_change`,
  `Html.on_composition_start`, `Html.on_composition_end`. These should stay only
  while they lower to the canonical event descriptor.
- `Html.on_custom(name, msg)`: keep as small sugar for a named event with
  `event_policy_none`. It must remain equivalent to `Html.on_event(name,
  Html.event_policy_none, msg)` and must not become a separate event path.
- Hot fixed event helpers route through file-local `Html` binding constructors
  and `Node.Attr.On(EventBinding)`. The host still lowers fixed bindings to the
  compact fixed-event execution path because moving pointer/click/input/check
  helpers to dynamic named events raised `stream_nodes_scanned_events` from 2 to
  33 in the `release-planner` structural update canary.
- Specialized form helpers such as `Html.on_submit_prevent_default`,
  `Html.required`, `Html.readonly`, `Html.bool_attr_if`,
  `Html.aria_describedby`,
  `Html.aria_invalid_s`, and `Html.aria_activedescendant_s`: keep when they hide
  a common policy, field, or naming detail without introducing a separate
  semantic path.
- `Html.behavior(name)`: keep as discoverable sugar for the runtime's
  `data-signals-behavior` marker. It should remain an element-scoped browser
  behavior hook, registered per mount and managed with attach/update/cleanup
  lifecycle, not grow into the deferred app-specific subscriptions or ports API
  and not become a public id route table.
- Rich-content rendering through ordinary `Elem.Element` plus text nodes: keep
  this as app/package-side structure. Do not add a raw HTML, `innerHTML`, or
  sanitizer surface unless repeated maintained apps prove that ordinary `Elem`
  construction plus app-local content policy is not enough.
- Fixed field helpers such as `Html.class_attr` and `Html.test_id`, structural
  constructors such as `Html.div`/`Html.form`, labeled metadata constructors
  such as `Html.form_label`/`Html.link`/`Html.section`, text helpers such as
  `Html.text`/`Html.text_s`/`Html.pre_s_c`/`Html.heading`/`Html.paragraph`/
  `Html.paragraph_s`,
  and element constructors such as `Html.button`/`Html.action_button`/
  `Html.text_input`/`Html.number_input`/`Html.textarea`/`Html.select`/
  `Html.option`/`Html.radio`/`Html.checkbox`, plus their focused `_c`, `_sc`,
  `_s`, and `_attrs` variants where shipped: keep as ergonomic sugar over the
  same descriptor vocabulary. `Html.number_input` and `Html.textarea` reuse the
  controlled text `value`/`input` path; number parsing remains an app commit
  reducer pattern. `Html.select` and `Html.option` are single-value form sugar
  over the existing text `value` field and `change` target-value payload.
  `Html.radio` is string-valued group sugar over the existing `value`, `checked`,
  and `change` target-value descriptors. `Html.checkbox` is bool-valued form
  sugar over the existing `checked` field and target-checked payload descriptor.
  Helper variants such as `Html.div_c`, `Html.div_sc`, `Html.heading_c`,
  `Html.paragraph_c`, `Html.paragraph_attrs`, `Html.paragraph_s_c`,
  `Html.button_s_c`, `Html.button_s_attrs`, `Html.action_button_c`,
  `Html.action_button_attrs`, and `Html.option_attrs` only bind common
  class/text/attr arguments earlier. None of these helpers introduce a new
  boundary leaf or wire path.
- `Signal.fake_task`: keep as deterministic app/spec sugar over the same task
  source model. It is useful for examples and native specs, but it should not
  become a separate async mechanism from host-backed tasks.
- `Signal.cleanup(name)`: keep as small constructor sugar for the current
  `Node.Cleanup` descriptor consumed by `Ui.on_cleanup`; do not grow it into a
  general lifecycle token API.
- `Http.get`, `Http.get_text_task`, `Http.get_text`, and `Http.error_text`: keep
  as convenience wrappers over `Http.request_task`/`Http.start` and
  `roc-lang/http` response values. The text helpers decode response bytes as
  UTF-8 for examples; richer JSON/body helpers should remain gated on a
  maintained app or focused canary proving the compiler builtin `Json` API is
  not enough.

## Removed Compatibility / ABI Notes

- Listener option bits are no longer public Roc constants and are no longer part
  of the Roc `EventBinding` ABI shape. `Node` no longer defines public policy
  constants or event binding constructors; `Html` passes typed `EventPolicy` and
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
  have been removed. Roc-side `EventExtractionPlan` byte values now live in the
  unexposed internal `EventExtraction` platform module instead of in `Ui`; keep
  them as module values because constructing the larger descriptor byte lists
  directly inside `State.on_key` regressed wasm mounting. A compact-id ABI trial
  was backed out after the scalar wrapper failed Roc construction, a single-field
  record read back as a pointer, a two-field record compiled but corrupted native
  fixture execution, and `roc glue` segfaulted before producing authoritative Zig
  layout. Zig derives a parsed
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
  now carry event extraction-plan bytes; JS parses the shared schema tags inside
  those bytes, rejects malformed record names, malformed DOM extraction
  source/leaf bytes, and impossible source/leaf pairs, and derives payload kind
  from the parsed schema. The wasm command encoder takes the parsed
  `boundary.BoundaryPayloadDescriptor` and serializes extraction bytes only at
  the browser wire edge. The browser runtime keeps the parsed boundary schema
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
- Native specs now dispatch fixed and named events through one canonical binding
  model. `real_click` covers propagation and supported default actions; direct
  `click` remains a low-level unit dispatch primitive.
- The platform no longer exposes a vendored `Json` module. Apps and fixtures use
  the compiler builtin `Json` module directly. The current JSON/body-codec spike
  is closed in `wip/research/json_codec_evidence.md`; it does not justify
  Signals HTTP/body JSON sugar, and the remaining wide-dashboard split parse is
  a Roc compiler workaround rather than a platform surface trigger.
- `Signal.task_source` remains a low-level constructor used by `Signal.fake_task`
  and `Http`. It is not documented as the ordinary app path and should not grow
  into a generic public effect registry. Future subscriptions or typed effect
  capabilities should replace ad hoc task-name conventions instead of widening
  this helper, and must reuse the shared boundary payload vocabulary plus
  capability-owned `HostValue` model instead of introducing a second interop
  payload format.
- `Signal.clone_expr`, `Signal.to_expr`, and `Signal.from_expr` remain exposed
  platform plumbing used by `Html` and `Ui` to share signal descriptors without
  compiler support for package-private helpers. They are not documented as the
  app-facing way to construct or inspect signals, and future API shrink work
  should avoid treating this leakage as a general signal descriptor API.

## Removal / Replacement Targets

- The fixed/named semantic split has been retired. Preserve fixed-event
  opcodes/slots only as host-local compression while measurements justify them;
  public API work should treat `Node.Attr.On(EventBinding)` as the single event
  model.
- Do not add more `_with` event helper families. Add a typed option/payload
  value when sugar cannot express a maintained app or focused canary.
- Do not add `Signal.map3` or higher-arity signal helper families. Use Roc
  record-builder syntax for named multi-signal composition and `Signal.combine`
  for homogeneous signal lists.
- Replace HTTP's current `http:send:` task-name prefix routing with a typed
  effect capability registry only when the subscriptions/app-interop work has a
  maintained app or focused canary to prove the shared task/subscription routing
  model. That registry should extend the same scope-owned source/effect boundary
  instead of exposing public ids or a browser-only channel table.
- Do not add HTTP fetch-policy knobs such as credentials, redirect, mode, cache,
  or referrer policy to the current helper layer without a maintained app or
  focused canary proving browser-default policy is insufficient. The current
  validation is closed in `wip/research/fetch_policy_evidence.md`. If promoted,
  the knobs should extend the package-aligned request transport path instead of
  creating a second Signals-only request model.
- Do not add a storage-only command-result side channel for failed
  local/session storage writes. The current validation in
  `wip/research/storage_command_result_evidence.md` keeps app-visible
  write-failure recovery behind a broader command/effect-result design.
- Keep file inputs, multi-select, browser constraint validation, focus commands,
  and selection-preserving mask/formatter behavior out of the general form helper
  set until a maintained app or focused canary proves a concrete browser-form
  gap. Browser-only details need JS contract coverage; native specs should stay
  focused on portable semantic outcomes.
