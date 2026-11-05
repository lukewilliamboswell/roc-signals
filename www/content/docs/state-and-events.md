+++
title = "State, Events, and Forms"
description = "Choosing state, writing handlers, binding form controls, validating input and deriving values."
weight = 5
template = "page.html"
+++

# State, Events, and Forms

The snippets on this page come from one sign-up form,
`www/samples/state.roc`.

## Introducing state

`Engine.state(initial, body)` creates a state and calls `body` with its
handle. Everything `body` returns can read and write it; nothing outside can.
Nesting states gives each its own layer:

{{ sample(file="state.roc", region="states") }}

Inside the inner state, the outer handle is lifted with `form.lift()` so it
can be used in the inner context. Name the contexts once:

{{ sample(file="state.roc", region="contexts") }}

State inside a list row or a conditional branch is created per row or per
branch, and released with it.

## Handlers

A handler is how an event changes state. It is built from a state handle and
attached to an element:

| Handler | The reducer receives |
|---|---|
| `st.update(f)` | the state |
| `st.update_by(v, f)` | the state and the value `v` reads when the event fires |
| `st.set_value(f)` | the state and the event's payload |
| `st.set_value_by(v, f)` | the state, `v`'s value and the payload |

The payload depends on the event: an `input` carries the control's new text, a
`change` on a checkbox or radio carries `"true"` or `"false"`, a `change` on a
select carries the chosen option's value, `keydown` carries the key, and a
click or submit carries nothing. `Html` attaches the usual ones for you:
`text_input` and `textarea` listen to `input`, `checkbox` and `select` to
`change`.

`update_by` is the tool for "which one": in a list row, `update_by(row.key(), f)`
passes the clicked row's key.

## One event, one transition

A handler writes one state. If an event must change several things at once —
a submit that marks the form as tried and counts a successful send — keep them
in one record and write one reducer:

{{ sample(file="state.roc", region="problems") }}

The engine applies the whole reducer before anything observes the result, so
the page never shows "tried" without the matching error messages.

## Forms and validation

{{ sample(file="state.roc", region="page") }}

A few things to note:

- Validation is a pure function, `problems`, and the messages are a second
  projection of the same `Problem` tags. The view never inspects rendered text.
- `aria_invalid` marks a field for assistive technology while its problem is
  shown.
- The runtime prevents the default action of every `submit`, so forms never
  navigate. A submit button's click submits its form, as in any browser.
- The compact toggle is a separate state, so toggling it re-evaluates only the
  class that reads it.

## Controlled inputs

A text box's `value` attribute is guarded, so the engine can rewrite it
without fighting the user:

- writing the value it already shows does nothing, so the caret stays put;
- a different value is held back while the box has focus or an IME
  composition is in progress, and applied when the box loses focus.

In practice: state written from a keystroke flows straight back, and a value
your app changes while the user is typing (clearing a draft after submit, for
example) appears when focus leaves the box. Checkboxes take `checked` as a
property, and a select re-applies its value when its options change.

## Derived values

`map` and `map2` compute a value every time something it reads changes. When
the computation is expensive, or many holes read its result, give it a layer
of its own with `derive`:

{{ sample(file="state.roc", region="derive") }}

`derive` evaluates its input once per change of the states it reads. If the
result is equal to the last one, nothing below it runs. Holes that read only
the derived value do no work on a keystroke that leaves it unchanged.
