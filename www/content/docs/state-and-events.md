+++
title = "State, Events, and Forms"
description = "Choosing state, handling events, binding form controls, and showing validation errors."
weight = 5
template = "page.html"
+++

# State, Events, and Forms

Use state for values the user can change, derive the values you can calculate,
and attach reducers or actions to events. The snippets below are fragments;
[Getting Started](@/docs/getting-started.md) covers the application imports.

## Local state

`Ui.state` introduces a source. It takes an initial value and a function that
receives a handle and returns the subtree using it:

```roc
Ui.state(
    initial,
    |model| {
        # ... build UI with `model` in scope
    },
)
```

The handle gives you:

- **`model.signal()`** — the current value, as a signal you can derive from.
- **`model.read(f)`** — shorthand for `model.signal().map(f)`.
- **reducers** — `update`, `update_str`, `update_bool`, `update_key`, `update_detail` — which
  build event handlers.
- **`model.set_cmd(next)`** — a replacement command for an action or lifecycle
  hook to return.

These are descriptions, not imperative assignments. The host applies a reducer
or a returned replacement command through the shared propagation engine.

State is scoped to where you declare it. Put it at the top of your app for
app-wide state, inside a `Ui.each` row renderer for per-row state, or inside
a `Ui.component` for reusable widget state. See
[Lists, Conditionals, and Components](@/docs/dynamic-structure.md).

### Type your state

Give related fields a record type and a named initial value:

```roc
Model : { name : Str, seats_draft : Str, seats : U64, accepted : Bool }

initial : Model
initial = { name: "", seats_draft: "1", seats: 1, accepted: False }
```

The numeric annotation makes the intended representation explicit. For a single
counter, `Ui.state(0.I64, ...)` is another way to choose an integer type.

Keep independent concerns in separate states when they should update
independently. A projection from a record is recalculated whenever that record
changes, even if the projected field is unchanged.

### Annotate the signal you map from

When receiver-style `.map` calls on one binding produce different result types,
annotate that binding:

```roc
state : Signal.Signal(Model)
state = model.signal()

name = state.map(|value| value.name)
seats = state.map(|value| value.seats)
```

This avoids a compiler inference limitation that can otherwise report an
incompatible `map` method. Explicit `Signal.map(state, ...)` calls are another
option. For a complicated calculation, an annotated pure helper can make both
the types and the application logic easier to follow.

## Reducers

A reducer is a pure function from current state (plus an event payload) to next
state. The handle method determines the payload:

| Method | Reducer signature | Payload |
| --- | --- | --- |
| `update` | `a -> a` | clicks, submits, blur — payload ignored |
| `update_str` | `a, Str -> a` | `input` / `change`, receives the field value |
| `update_bool` | `a, Bool -> a` | checkbox change, receives checked state |
| `update_key` | `a, KeyPayload -> a` | `keydown`, receives `{ key, shift_key }` |
| `update_detail` | `a, Str -> a` | custom events, receives `event.detail` as text |

The event attribute chooses when the reducer runs; the state method chooses
which payload it receives. For example, `Html.on_blur(model.update(...))`
ignores the blur payload and updates `model`.

An annotated helper is useful for a reducer with parsing or validation:

```roc
commit_seats : Model -> Model
commit_seats = |model|
    match U64.from_str(model.seats_draft) {
        Ok(value) => { ..model, seats: value }
        Err(_) => { ..model, seats_draft: model.seats.to_str() }
    }
```

Then attach it: `Html.on_blur(model.update(commit_seats))`.

## Actions with declared reads

Use `Ui.action(reads, to_cmd)` when a click or submit should run a command using
the current values of independent signals. For example, with `source` and
`result` state handles in scope:

```roc
Html.button(
    "Append snapshot",
    Ui.action(
        { source: source.signal(), result: result.signal() }.Signal,
        |reads| result.set_cmd("${reads.result}|${reads.source}"),
    ),
)
```

The callback sees settled values for the declared reads. Each accepted event
invokes it, including repeated clicks with identical reads. Changing a read
does **not** invoke it. Return a task, navigation, storage, or state command;
do not add serial counters just to make repeated clicks look like value changes.

The mounted event's scope owns its read graph and any task it starts. Disposing
that scope removes the handler, releases its read edges, and cancels its work.
`Ui.action` accepts payload-free events. For typed payloads, use `Ui.action_str`,
`Ui.action_bool`, `Ui.action_key`, or `Ui.action_detail`. Their callbacks receive
`(reads, payload)`; extraction matches the corresponding `State.on_*` method.
The state reducers remain the compact choice when one state is both the only
read and the only destination.

```roc
Html.on_custom(
    "package-preview",
    Ui.action_detail(settings.signal(), |current_settings, detail|
        preview.set_cmd(render_preview(current_settings, detail))),
)
```

## Updating several states together

An action can replace several distinct states in one turn. Build each proposal
with `state.write(next)`, then return `Ui.update_states(writes)`. For example,
changing a search query can reset pagination without briefly requesting the new
query at the old page:

```roc
query_changed = Ui.action_str(query.signal(), |_current_query, text|
    Ui.update_states([query.write(text), page.write(1)]))
```

Derived values, conditional branches, and value-change observers see the
complete proposed snapshot, regardless of the order of these writes. Equal
replacements are pruned. Each destination may appear only once, including
unchanged destinations; duplicates are programmer errors. An empty list does
nothing.

`set_cmd` and coordinated-write commands capture replacement values, not live
reads. They can safely be stored and returned repeatedly; each execution creates
fresh owned proposals. Use an action's explicit reads when the replacement must
depend on the current state. Separate commands returned by separate observers
remain separate turns, not one coordinated write set.

## Deriving values

`.map` for one input:

```roc
greeting = name.map(|value| "Hello, ${value}")
```

The **record-builder** form for several. `{ a: signal_a, b: signal_b }.Signal`
turns a record of signals into a signal of a record:

```roc
totals : Signal.Signal({ price : U64, qty : U64 })
totals = { price: price, qty: qty }.Signal

total_text : Signal.Signal(Str)
total_text = totals.map(|v| "Total: ${(v.price * v.qty).to_str()}")
```

Named fields identify the inputs when the calculation needs several values.

`Signal.map2` combines two inputs. `Signal.combine` accepts a list of signals
with the same value type and produces a signal of the corresponding list.

When homogeneous inputs naturally produce a different collection or aggregate,
`Signal.combine_map(signals, project)` applies `project` in that same combine
node. For example, a keyed `Rows` value can be derived without adding a second
`map` node solely to convert the combined list.

For keyed selection, use `Signal.select : Signal(Str), Str -> Signal(Bool)`:

```roc
is_selected = Signal.select(selected_key, row_key)
```

The host indexes members by their string key. Changing `selected_key` dirties
only the members for the old and new keys, independent of the list size. The
selector itself runs no Roc transform; any `map` you place downstream still
counts as ordinary derived work for the members that changed.

When each row needs one of two stable values, construct the keyed selector once
outside the row builder, then select from it inside each row:

```roc
selection_class = selected_key.keyed("selected", "")
Ui.each(rows, |row|
    Html.div([Html.class_attr_s(row.select(selection_class))], [Html.text(row.key())]))
```

The fused form preserves the same exact-key index and O(old-plus-new-key)
dirtiness while sharing its typed capability and initializers across rows.

## Form controls

The form helpers bind a signal to the control's value or checked state. Their
events send the edited value to a reducer or action.

### Text and textarea

```roc
Html.text_input("Name", name, model.update_str(|v, text| { ..v, name: text }))
Html.textarea("Bio", bio, model.update_str(|v, text| { ..v, bio: text }))
```

Variants: `_c` adds a class string, `_attrs` adds a list of attributes.

For text-like controls, an equal value write is a no-op. A differing write is
deferred while the control is focused or composing and applied after blur unless
a later input echo already matched it. Account for this when normalizing input: a
state change may not immediately replace text being edited. Test selection and
IME behavior in a browser for your particular interaction.

### Number input

Number fields keep the browser's **draft text** while editing, because
half-typed input is not a number. Store the draft as a `Str` and parse it on a
commit event:

```roc
Html.number_input_attrs(
    "Seats",
    seats_draft,
    [Html.on_blur(model.update(commit_seats))],
    model.update_str(|v, text| { ..v, seats_draft: text }),
)
```

Keeping `seats_draft : Str` and `seats : U64` separate lets editing proceed
without committing every intermediate string. The `commit_seats` reducer above
accepts a valid integer and restores the previous number for an invalid draft.
A browser number input may itself restrict or normalize the text it exposes.

### Select

```roc
Html.select(
    "Plan",
    plan,
    [Html.option("starter", "Starter"), Html.option("growth", "Growth")],
    model.update_str(|v, text| { ..v, plan: text }),
)
```

`Html.option(value, label)`. The select's signal is the canonical selected
value; `change` delivers the chosen option's value. Single-select only —
multi-select is not implemented.

### Radio groups

Radios are string-valued. Each option derives its own checked state from the
shared value signal:

```roc
Html.radio("Monthly", "billing", "monthly", billing, model.update_str(set_billing))
Html.radio("Annual", "billing", "annual", billing, model.update_str(set_billing))
```

Arguments are `(label, group_name, option_value, selected_signal, msg)`.

### Checkbox

```roc
Html.checkbox("Accept terms", accepted, model.update_bool(|v, checked| { ..v, accepted: checked }))
```

### Buttons

```roc
Html.button("Save", model.update(save))                          # static label
Html.button_s(label_signal, model.update(save))                  # signal label
Html.action_button(label_signal, disabled_signal, model.update(save))
```

`action_button` binds both the label and `disabled` to signals.

Inside a `<form>`, a button with no `type` acts as a submit button. Give
independent buttons `Html.attr("type", "button")` so they do not also submit.

## Attributes

| Need | Helper |
| --- | --- |
| Static class | `Html.class_attr("...")` |
| Signal class | `Html.class_attr_s(signal)` |
| Static attribute | `Html.attr("placeholder", "...")` |
| Signal attribute | `Html.attr_s("data-state", signal)` |
| Optional signal attribute | `Html.attr_maybe_s(name, signal_of_none_or_some)` |
| Static boolean | `Html.bool_attr("hidden")`, `Html.required`, `Html.readonly` |
| Conditional boolean attribute list | `Html.bool_attr_if("hidden", condition)` |
| Signal boolean | `Html.bool_attr_s("hidden", signal)` |
| Test hook | `Html.test_id("chart")` |

`bool_attr_if` returns a list containing zero or one attribute; concatenate it
with the other attributes rather than placing it inside an attribute list.

`attr_maybe_s` supports removing an attribute as well as setting its text.
`None` removes the attribute; `Some(value)` sets it:

```roc
menu_target : Signal.Signal([None, Some(Str)])
menu_target = state.map(|v| if v.picked.is_empty() { None } else { Some(v.picked) })

Html.aria_activedescendant_s(menu_target)
```

Use a signal-backed class when the same elements should remain mounted.
Changing a `Ui.when` branch gives its contents a new lifetime.

## Events

Fixed helpers cover the common surface: `on_pointer_down`, `on_pointer_up`,
`on_pointer_enter`, `on_pointer_leave`, `on_focus`, `on_blur`, `on_change`,
`on_key_down`, `on_composition_start`, `on_composition_end`, and
`on_submit_prevent_default`.

### Keyboard

```roc
Html.on_key_down(model.update_key(|v, payload| { ..v, last_key: payload.key }))
```

`Ui.KeyPayload` is `{ key : Str, shift_key : Bool }`. The JavaScript runtime
reads the DOM event and hands Roc typed bytes; you never touch a `KeyboardEvent`.

### Custom events

For JavaScript widgets that emit `CustomEvent`, `on_custom` binds by name and
`update_detail` receives `event.detail` as text:

```roc
Html.div(
    [
        Html.test_id("chart"),
        Html.on_custom("chart-select", model.update_detail(|v, detail| { ..v, picked: detail })),
    ],
    [Html.text("Chart")],
)
```

### Event policies

Event policies describe browser behavior such as preventing the default action
or stopping propagation. Attach a policy to the binding:

```roc
Html.on_event("pointerdown", Html.event_policy_stop_propagation, model.update(open_menu))
```

Constants: `event_policy_none`, `event_policy_prevent_default`,
`event_policy_stop_propagation`, `event_policy_stop_immediate`. For rarer
combinations, build the record:

```roc
self_capture = { ..Html.event_policy_none, capture: True, self: True }
Html.on_event("click", self_capture, model.update(select_self_only))
```

The typical use is a nested control inside a draggable or clickable parent that
must not trigger the parent's handler.

A link can keep a real `href` and handle navigation with an event policy. Check
modified clicks and keyboard activation in the browser: unconditional
`prevent_default` is not a policy that distinguishes ordinary clicks from
Ctrl-click or Command-click.

## Validation

Keep validation rules in pure functions and derive error messages from state.
For example, an invitation form can track whether a submission has been
attempted separately from whether the values are valid:

```roc
Invite : { email : Str, accepted : Bool, attempted : Bool }

can_submit : Invite -> Bool
can_submit = |value| (!value.email.is_empty()) and value.accepted
```

This is only a presence check; use your application's actual email rules where
appropriate. With `model : Ui.State(Invite)` in scope:

```roc
state : Signal.Signal(Invite)
state = model.signal()

email = state.map(|value| value.email)
email_invalid = state.map(|value| value.attempted and value.email.is_empty())
email_message = state.map(
    |value| if value.attempted and value.email.is_empty() { "Enter an email address." } else { "" },
)
```

Connect the message to the input using `aria-describedby` and give the message
a stable test id:

```roc
Html.text_input_attrs(
    "Invite email",
    email,
    [
        Html.aria_describedby("invite-email-message"),
        Html.aria_invalid_s(email_invalid),
    ],
    model.update_str(|value, text| { ..value, email: text }),
)

Html.div(
    [Html.attr("id", "invite-email-message"), Html.test_id("email-error")],
    [Html.text_s(email_message)],
)
```

Use an action to submit. In this fragment, `task` is a declared task accepting a
string request, as described in [Effects, HTTP, and the Browser](@/docs/effects-and-browser.md):

```roc
submit = Ui.action(
    state,
    |value|
        if can_submit(value) {
            Signal.start_str(task, value.email)
        } else {
            model.set_cmd({ ..value, attempted: True })
        },
)
```

A valid submission starts the request. An invalid one updates the state so the
messages appear. Repeating a valid submission with the same email still runs
the action; it needs no counter or suffix in the request value.

Bind this handler to the form with `Html.on_submit_prevent_default(submit)` so
keyboard submission follows the same validation path. If a separate button also
binds `submit`, give it `Html.attr("type", "button")` to avoid handling the click
and the form's default submit as two requests. Alternatively, use a submit
button and let the form own submission.

Let users attempt an invalid form if that is how your UI reveals errors.
Disabling its only submission control while invalid can prevent them from
learning what needs attention. If requests must not overlap, derive a busy flag
from task and application state, disable submission while busy, and check the
same condition in the handler. A disabled button alone does not guard other
submission paths.

A native spec can assert that invalid input reveals the message and starts no
work. Assuming the form is named `"Invite form"` and the task `"form-submit"`:

```lisp
(submit (role form :name "Invite form"))
(expect-text (test-id "email-error") "Enter an email address.")
(expect-attr (label "Invite email") aria-invalid "true")
(expect-pending-task "form-submit" 0)
```

Also test the real browser path. Native specs do not implement the browser's
full constraint-validation behavior for attributes such as `required` and
`type="email"`.

## Accessible controls

Give controls names that explain their purpose. The helpers provide role and
label metadata that native specs can locate, while `aria-describedby` connects
extra instructions or error messages to controls. For repeated controls, make
the context understandable and use stable test ids where a locator would
otherwise be ambiguous.

Names and passing native specs do not establish keyboard or screen-reader
usability. Test tab order, activation, error announcements, and focus after
structural changes in a browser. The current public command API has no general
focus command; account for that limitation when designing dialogs or workflows
that require moving focus.

Arbitrary attributes let you express additional semantics, but the native
locator model is narrower than the browser accessibility tree. A custom
`Html.attr("role", "dialog")` is a browser attribute rather than the built-in
role metadata used by native role locators; use a test id for that native target.

## Next

[Lists, Conditionals, and Components](@/docs/dynamic-structure.md) covers dynamic
structure and the lifetime of its state.
