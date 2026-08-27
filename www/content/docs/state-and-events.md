+++
title = "State, Events, and Forms"
description = "Local state, reducers, every input control, attributes, event policies, and the validation pattern."
weight = 5
template = "page.html"
+++

# State, Events, and Forms

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

The handle gives you exactly two things:

- **`model.signal()`** — the current value, as a signal you can derive from.
- **reducers** — `on_unit`, `on_str`, `on_bool`, `on_key`, `on_detail` — which
  build event handlers.

There is no setter. You never assign to state; you attach a reducer to an event
and the host applies it.

State is scoped to where you declare it. Put it at the top of your app for
app-wide state, inside a `Ui.each_str` row renderer for per-row state, or inside
a `Ui.component` for reusable widget state. See
[Lists, Conditionals, and Components](@/docs/dynamic-structure.md).

### Type your state

Annotate the state type and give it a named `initial`. This avoids numeric
literals defaulting to `Dec` and makes error messages far more readable:

```roc
Model : { name : Str, seats : U64, accepted : Bool }

initial : Model
initial = { name: "", seats: 1, accepted: False }
```

A bare `0` with nothing to constrain it becomes a `Dec`, so `n.to_str()` renders
`"0.0"` instead of `"0"`. The compiler *sometimes* warns (`LITERAL DEFAULTED`),
but often does not — in the counter above it compiles clean and you only find
out by looking at the rendered UI. Annotate the state type and this stops being
possible.

### Annotate the signal you map from

This one is worth its own section, because the error message does not point at
the fix.

Calling `.map` twice on the same binding with **different result types** fails:

```roc
# Does NOT compile.
state = model.signal()

name = state.map(|value| value.name)     # wants Signal(Str)
count = state.map(|value| value.count)   # wants Signal(U64)
```

```text
TYPE MISMATCH ─ The `map` method on `Signal` has an incompatible type.
```

The fix is to annotate the binding you are mapping *from*:

```roc
state : Signal.Signal(Model)
state = model.signal()

name = state.map(|value| value.name)     # fine
count = state.map(|value| value.count)   # fine
```

Annotating the receiver generalizes it, so each `.map` call can be instantiated
at its own result type. Derived bindings then infer fine on their own.

Two related habits that prevent the same class of error:

- **Function parameters are already concrete**, so a signal passed into a
  function never needs this. That is why Conduit's page modules take
  `Signal.Signal(Api.Remote(...))` parameters and map freely.
- **Chained method calls need a concrete type somewhere in the chain.** Once
  the receiver above is annotated, an inline chain like
  `items.keep_if(...).len()` compiles fine. But if the type is still
  unresolved at that point — typically because you skipped the receiver
  annotation — you get a confusing secondary error:

  ```text
  MISSING METHOD ─ This is trying to dispatch a method named `to_str` on
  an unresolved type variable, but unresolved type variables have no methods.
  ```

  Pulling the chain into an annotated helper sidesteps the problem entirely and
  reads better:

  ```roc
  unread_count : List(Book) -> U64
  unread_count = |books| books.keep_if(|book| !book.read).len()

  summary = books.map(|items| "${unread_count(items).to_str()} left")
  ```

  The helper is also directly unit-testable, which the inline version is not.

## Reducers

A reducer is a pure function from current state (plus an event payload) to next
state. The handle method determines the payload:

| Method | Signature | Fires on |
| --- | --- | --- |
| `on_unit` | `a -> a` | clicks, submits, blur — payload ignored |
| `on_str` | `a, Str -> a` | `input` / `change`, receives the field value |
| `on_bool` | `a, Bool -> a` | checkbox change, receives checked state |
| `on_key` | `a, KeyPayload -> a` | `keydown`, receives `{ key, shift_key }` |
| `on_detail` | `a, Str -> a` | custom events, receives `event.detail` as text |

Write reducers as annotated top-level functions whenever they are more than a
line. They are ordinary pure functions, so they are easy to read and easy to
test directly:

```roc
commit_seats : Model -> Model
commit_seats = |model|
    match U64.from_str(model.seats_draft) {
        Ok(value) => { ..model, seats: value }
        Err(_) => { ..model, seats_draft: model.seats.to_str() }
    }
```

Then attach it: `Html.on_blur(model.on_unit(commit_seats))`.

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

Use this instead of looking for `map3` or `map4` — there deliberately isn't one.
Named fields stay readable as the number of inputs grows, and the edges are
declared just as explicitly.

`Signal.map2` exists for two inputs, and `Signal.combine : List(Signal(a)) ->
Signal(List(a))` for a homogeneous list. In practice the record builder covers
nearly everything.

## Form controls

Every control is **controlled**: its displayed value comes from a signal, and
its events dispatch reducers. There is no uncontrolled mode.

### Text and textarea

```roc
Html.text_input("Name", name, model.on_str(|v, text| { ..v, name: text }))
Html.textarea("Bio", bio, model.on_str(|v, text| { ..v, bio: text }))
```

Variants: `_c` adds a class string, `_attrs` adds a list of attributes.

The runtime will not fight the user: it does not overwrite the value of a
focused input mid-composition, so IME input and mid-word edits behave correctly.

### Number input

Number fields keep the browser's **draft text** while editing, because
half-typed input is not a number. Store the draft as a `Str` and parse it on a
commit event:

```roc
Html.number_input_attrs(
    "Seats",
    seats_draft,
    [Html.on_blur(model.on_unit(commit_seats))],
    model.on_str(|v, text| { ..v, seats_draft: text }),
)
```

Keeping `seats_draft : Str` and `seats : U64` as separate fields means a user
typing `1` on the way to `12` never has their input rejected.

### Select

```roc
Html.select(
    "Plan",
    plan,
    [Html.option("starter", "Starter"), Html.option("growth", "Growth")],
    model.on_str(|v, text| { ..v, plan: text }),
)
```

`Html.option(value, label)`. The select's signal is the canonical selected
value; `change` delivers the chosen option's value. Single-select only —
multi-select is not implemented.

### Radio groups

Radios are string-valued. Each option derives its own checked state from the
shared value signal:

```roc
Html.radio("Monthly", "billing", "monthly", billing, model.on_str(set_billing))
Html.radio("Annual", "billing", "annual", billing, model.on_str(set_billing))
```

Arguments are `(label, group_name, option_value, selected_signal, msg)`.

### Checkbox

```roc
Html.checkbox("Accept terms", accepted, model.on_bool(|v, checked| { ..v, accepted: checked }))
```

### Buttons

```roc
Html.button("Save", model.on_unit(save))                          # static label
Html.button_s(label_signal, model.on_unit(save))                  # signal label
Html.action_button(label_signal, disabled_signal, model.on_unit(save))
```

`action_button` is the common case for async work: signal-backed label *and*
signal-backed `disabled`.

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
| Conditional boolean | `Html.bool_attr_if("hidden", condition)` |
| Signal boolean | `Html.bool_attr_s("hidden", signal)` |
| Test hook | `Html.test_id("chart")` |

`attr_maybe_s` is for attributes that must be genuinely **absent**, not empty.
`None` removes the attribute; `Some(value)` sets it:

```roc
menu_target : Signal.Signal([None, Some(Str)])
menu_target = state.map(|v| if v.picked.is_empty() { None } else { Some(v.picked) })

Html.aria_activedescendant_s(menu_target)
```

Prefer signal-backed classes over conditional structure. Changing a class is one
patch; swapping a `Ui.when` branch tears down and rebuilds a subtree.

## Events

Fixed helpers cover the common surface: `on_pointer_down`, `on_pointer_up`,
`on_pointer_enter`, `on_pointer_leave`, `on_focus`, `on_blur`, `on_change`,
`on_key_down`, `on_composition_start`, `on_composition_end`, and
`on_submit_prevent_default`.

### Keyboard

```roc
Html.on_key_down(model.on_key(|v, payload| { ..v, last_key: payload.key }))
```

`Ui.KeyPayload` is `{ key : Str, shift_key : Bool }`. The JavaScript runtime
reads the DOM event and hands Roc typed bytes; you never touch a `KeyboardEvent`.

### Custom events

For JavaScript widgets that emit `CustomEvent`, `on_custom` binds by name and
`on_detail` receives `event.detail` as text:

```roc
Html.div(
    [
        Html.test_id("chart"),
        Html.on_custom("chart-select", model.on_detail(|v, detail| { ..v, picked: detail })),
    ],
    [Html.text("Chart")],
)
```

### Event policies

`preventDefault`, `stopPropagation`, capture, and friends are **static data**
attached to the binding, not something you call at runtime:

```roc
Html.on_event("pointerdown", Html.event_policy_stop_propagation, model.on_unit(open_menu))
```

Constants: `event_policy_none`, `event_policy_prevent_default`,
`event_policy_stop_propagation`, `event_policy_stop_immediate`. For rarer
combinations, build the record:

```roc
self_capture = { ..Html.event_policy_none, capture: True, self: True }
Html.on_event("click", self_capture, model.on_unit(select_self_only))
```

The typical use is a nested control inside a draggable or clickable parent that
must not trigger the parent's handler.

Links that navigate within the app use the same mechanism — Conduit's `Nav.link`
attaches `event_policy_prevent_default` to a real `<a href>`, so middle-click and
"open in new tab" still work while normal clicks route in-app.

## Validation

Validation is derived state. There is no validation API and no integration with
browser constraint validation — you already have everything you need.

Keep three things separate: **whether a submit has been attempted**, **whether
the data is valid**, and **whether a request is in flight**.

```roc
can_submit : Model -> Bool
can_submit = |model| (!model.email.is_empty()) and model.accepted

email_invalid : Signal.Signal(Bool)
email_invalid = state.map(|v| v.attempted and v.email.is_empty())

email_message : Signal.Signal(Str)
email_message = state.map(
    |v|
        if v.attempted and v.email.is_empty() {
            "Enter an email address."
        } else {
            ""
        },
)
```

Wire the invalid flag to `aria-invalid`, point `aria-describedby` at a real
element holding the message, and disable the submit button from a derived
signal:

```roc
Html.text_input_attrs(
    "Invite email",
    email,
    [
        Html.aria_describedby("invite-email-message"),
        Html.aria_invalid_s(email_invalid),
    ],
    model.on_str(|v, text| { ..v, email: text }),
),
Html.div([Html.attr("id", "invite-email-message")], [Html.text_s(email_message)]),
Html.action_button(Signal.const("Send invite"), submit_disabled, model.on_unit(submit_if_valid)),
```

The submit reducer marks the attempt and, when valid, changes a *request* signal
that a `Ui.on_change` turns into an actual request — see
[Effects, HTTP, and the Browser](@/docs/effects-and-browser.md).

```roc
submit_if_valid : Model -> Model
submit_if_valid = |model|
    if can_submit(model) {
        next = model.submit_count + 1
        { ..model, attempted: True, submit_count: next, submit_request: "${model.email}#${next.to_str()}" }
    } else {
        { ..model, attempted: True }
    }
```

Including the counter in the request string matters: it makes two identical
submissions produce two *different* values, so the change actually propagates.
Without it, `is_eq` would correctly suppress the second one.

**Attach the reducer to the form, not only the button.** A disabled button
cannot be clicked, so if the submit button is disabled while the form is
invalid, clicking it can never set `attempted` and the user never sees why. The
form's `on_submit_prevent_default` handler is what reveals the errors:

```lisp
(expect-disabled (role button :name "Send invite") true)
(submit (role form :name "Invite form"))
(expect-text (text "Enter an email address.") "Enter an email address.")
(expect-attr (label "Invite email") aria-invalid "true")
(expect-pending-task "form-submit" 0)

(fill (label "Invite email") "ops@example.com")
(check (label "Accept terms"))
(expect-disabled (role button :name "Send invite") false)
(click (role button :name "Send invite"))
(expect-pending-task "form-submit" 1)
```

Note `(expect-pending-task "form-submit" 0)` — the invalid submit marked the
fields and started no request. That assertion is the whole point of the pattern.

This is locked by the `form-validation-pattern` fixture and used by every form
in Conduit.

## Naming is load-bearing

Roles and accessible names are not decoration. `Html.section`,
`Html.form_label`, `Html.link`, `Html.heading`, and every input take a label,
and the native test runner locates elements by exactly those roles and names.
An unnamed control is an untestable one, which is useful pressure.

Be clear about what that does *not* buy you, though: naming is one part of
accessibility and the platform helps with almost none of the rest. There is no
programmatic focus, so no focus trap, no focus restoration after a dialog, and
no focus-on-first-error. There are no live-region helpers, no dialog semantics,
and no roving-tabindex support. A perfectly named, completely
keyboard-inaccessible app will pass every spec you write.

Custom `role` attributes are also invisible to native specs — `Html.attr("role",
"dialog")` sets a real attribute in the browser, but `role:` locators only
resolve roles set by the built-in helpers. Use `test_id:` for anything else.

## Next

[Lists, Conditionals, and Components](@/docs/dynamic-structure.md) — dynamic
structure and where identity comes from.
