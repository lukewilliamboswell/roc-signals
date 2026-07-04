# Form And Input Evidence

Captured: 2026-07-03.

Purpose: keep shipped controlled input and browser-form evidence out of the
active backlog. Promote new form/input surface only when a maintained app or
focused canary proves a concrete browser-form gap.

Refresh check: re-run on 2026-07-04 with the focused browser form contract,
Zig simulated-DOM/spec-runner subset, and full native spec suite; the current
surface and fixture coverage below remained green.

## Focused Gates

For evidence-only edits that do not change current-state or coverage claims, run:

```sh
git diff --check
zig build run-check-tidy
```

For browser/runtime controlled-input and form coverage claims, run:

```sh
node --test --test-name-pattern "controlled input|SetValue|payloads round-trip|select|radio|textarea|number input|submit|form" scripts/browser/runtime_contract.test.mjs
```

For native/app spec coverage claims, run:

```sh
python3 scripts/test.py native --native always
```

For Zig-only form/default-action internals, use:

```sh
zig build run-test-zig -Dtest-filter="simulated DOM controlled" -Dtest-filter="spec runner"
```

## Current Shipped Surface

- `Html.text_input`, `Html.text_input_c`, and `Html.text_input_attrs` bind a
  signal-backed text value and dispatch `state.on_str` from the input target
  value.
- `Html.number_input`, `Html.number_input_c`, and `Html.number_input_attrs` keep
  the browser draft as text; apps parse and commit on events such as blur/change.
- `Html.textarea`, `Html.textarea_c`, and `Html.textarea_attrs` share the
  controlled text contract with text inputs.
- `Html.select`, `Html.select_c`, `Html.select_attrs`, `Html.option`, and
  `Html.option_attrs` cover single-value selects with string target-value
  dispatch.
- `Html.radio`, `Html.radio_c`, and `Html.radio_attrs` cover string-valued radio
  groups with signal-backed checked state.
- `Html.checkbox`, `Html.checkbox_c`, and `Html.checkbox_attrs` cover
  signal-backed boolean checked state and `state.on_bool`.
- `Html.on_submit_prevent_default` is the explicit app-managed submit helper.
- `Html.attr_maybe_s` and `Html.aria_activedescendant_s` provide honest absence
  semantics for signal-backed optional text attributes.
- `Html.action_button`, `Html.action_button_c`, and `Html.action_button_attrs`
  cover signal-backed disabled action buttons.
- `Html.required`, `Html.readonly`, `Html.aria_invalid_s`, and
  `Html.aria_describedby` support the documented validation pattern without
  host-managed constraint validation.

## JS Runtime Coverage

- `scripts/browser/runtime_contract.test.mjs` covers guarded `SetValue`
  reconciliation: unfocused writes apply immediately, equal writes clear stale
  pending state, focused differing writes defer, composition defers until blur,
  user echoes clear pending writes, and node removal clears pending state and
  listeners.
- The same runtime suite covers fixed bool/checkbox payload dispatch, controlled
  select value sync before Roc echo, radio target-value dispatch, textarea
  guarded `SetValue`, number-input draft strings while focused, dynamic submit
  static prevent-default policy, and named form events with unit and target-value
  payloads.

## Native And App Spec Coverage

- `src/sim_dom.zig` unit tests cover native guarded controlled values, pending
  canonical value replacement, no-op user echo, and composition deferral until
  blur.
- `src/spec/spec_runner.zig` unit tests cover `real_click` form submit/reset
  default actions, checkbox default checked changes, radio target-value default
  changes, `select_option`, Enter-key text-input submit default action, and direct
  semantic `submit` dispatch for enabled unit submit bindings.
- `examples/_fixtures/controlled-input-contract/spec.txt` proves focused text
  input reconciliation, composition deferral, blur flush, and user echo behavior.
- `examples/_fixtures/textarea-control/spec.txt` proves textarea focus/blur and
  controlled text reconciliation.
- `examples/_fixtures/number-input-control/spec.txt` proves number input draft
  string editing and app-level commit/error handling.
- `examples/_fixtures/select-control/spec.txt` proves single-value select option
  changes and change-event counts.
- `examples/_fixtures/radio-group-control/spec.txt` proves string-valued radio
  group default action and checked-state updates.
- `examples/_fixtures/checkbox-real-click/spec.txt` proves checkbox real-click
  default action toggles checked state and delivers boolean changes.
- `examples/_fixtures/submit-button-default/spec.txt` proves implicit submit
  buttons, explicit `type="submit"`, `type="button"` opt-out, and direct semantic
  submit.
- `examples/_fixtures/form-reset-default/spec.txt` proves reset-button default
  action for app-managed forms.
- `examples/_fixtures/form-validation-pattern/spec.txt` proves the documented
  validation pattern: derived validation text, optional `aria-invalid`, disabled
  submit state, submit task start only when valid, and task completion.
- `examples/_fixtures/optional-text-attr/spec.txt` proves optional text attrs are
  removed when absent and set when present.
- `examples/team-signup/spec.txt` keeps a maintained-app canary for required,
  readonly, ARIA validation attrs, checkbox state, and valid-submit behavior.

## Result

The shipped form/input milestone is covered for guarded text reconciliation,
signal-backed text/number/textarea/select/radio/checkbox helpers, submit/reset
default actions, optional text attrs, action-button disabled state, and
app-authored validation patterns.

Remaining form/input work should stay gated:

Promotion trigger: name one maintained app or focused canary and one concrete
browser-form gap that the shipped controlled input and submit/reset surface does
not cover.

- Selection-preserving normalization for masks/formatters only when a maintained
  app or focused canary needs caret-preserving focused edits. The proof must
  include JS contract coverage for `selectionStart`/`selectionEnd` behavior and
  app/native coverage for the semantic committed value.
- File inputs as browser-owned uncontrolled controls with explicit event payloads.
  The proof must keep file objects/browser handles out of native specs while
  covering the app-visible payload semantics.
- Multi-select or richer select/radio semantics only when state in a maintained
  app or focused canary proves the single-value helpers are insufficient. The
  proof must show why general attrs, `Html.on_event`, and current target-value
  payloads are not enough.
- Browser constraint validation integration, app-visible focus commands, or
  date/time helpers only when host involvement is required. Browser-only timing
  and validity quirks belong in JS contract tests; native specs should assert
  portable semantic outcomes only.
