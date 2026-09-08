+++
title = "Thinking in Signals"
description = "How state, derived values, events, and scopes work together in a Roc Signals app."
weight = 2
template = "page.html"
+++

# Thinking in Signals

A signal represents a value that can change while an app is running. You describe
how other values depend on it, then bind the results to text, controls, or other
parts of the UI. The runtime keeps those bindings up to date.

This page introduces that model with a counter. The examples are fragments using
`Ui`, `Html`, and `Signal`; [Getting Started](@/docs/getting-started.md) shows the
imports and application entry point.

## State, a calculation, and some text

```roc
Ui.state(
    0.I64,
    |count| {
        label = count.signal().map(|n| "Count: ${n.to_str()}")

        Html.div(
            [],
            [
                Html.paragraph_s(label),
                Html.button("Increment", count.on_unit(|n| n + 1)),
            ],
        )
    },
)
```

`Ui.state` gives the counter an initial value and passes a state handle to the
function that builds its UI. `count.signal()` describes the current count.
Calling `.map` describes a calculation that turns each count into a label.
`Html.paragraph_s` displays that label; the `_s` suffix means the helper accepts
a signal.

The button binds a **reducer**: a pure function from the current count to the
next count. When clicked, the runtime calls `|n| n + 1`, updates the state,
recalculates the label, and changes the paragraph's text.

```text
count ──▶ label ──▶ paragraph text
```

These dependencies form a graph. A **source** supplies a value, a **derived
signal** calculates a value from its inputs, and a **sink** uses a value in the
UI or in a command. Local state is one kind of source. Timers, task results,
and browser values such as the current location are others.

The runtime follows the declared dependencies when a source changes. In this
counter, unrelated parts of the app need no recalculation. The reducer and
calculation still have their own costs: putting a large list scan inside one
`map` does not make that scan cheap.

## Describing a calculation does not run it now

`Signal.map` returns a description of a calculation. The runtime evaluates it
when its value is needed for the mounted UI, caches the result, and recalculates
it when an input changes. This differs from `List.map`, which runs over a list
and returns another list immediately.

For changing text, pass a signal to a signal-backed helper:

```roc
greeting = name.map(|value| "Hello, ${value}")
Html.text_s(greeting)
```

By comparison, `Html.text("Hello")` describes fixed text. Computing a string
from an initial value and passing it to `Html.text` does not create a dependency
on later state.

## When your functions run

The runtime calls `main()` once per mount. State updates do not call it again.
It retains the descriptions and callbacks needed to update the app.

| Function | When it runs |
| --- | --- |
| `main` | When the app mounts |
| The bodies passed to `Ui.state` and `Ui.component` | When those descriptions are constructed |
| A `Ui.when` or `Ui.switch` branch builder | When that branch becomes live |
| A `Ui.each` row builder | When a new keyed row becomes live |
| A `map` transform | For initial evaluation and when an input changes |
| A reducer or action handler | When its event is accepted |
| An `Ui.on_change` callback | After its observed value changes and propagation settles |

Construction can happen after startup. Adding a list row or selecting a new
branch builds its description, including any state and components inside it.
Updating a surviving row's data keeps its existing scope and propagates through
its row signal.

## Combining inputs

A calculation declares its inputs at the call site. There is no unrestricted
`signal.get()` operation that reads state from anywhere in your code. The
runtime passes current values to the callbacks that declared those reads.

For several inputs, use Roc's record-builder syntax:

```roc
totals : Signal.Signal({ price : U64, qty : U64 })
totals = { price: price, qty: qty }.Signal

total_text = totals.map(|value| "Total: ${(value.price * value.qty).to_str()}")
```

Here `price` and `qty` are signals. The `.Signal` builder produces a signal of
a record containing their current values. Either input can cause the total to
be recalculated. The runtime evaluates dependent calculations in dependency
order, so a calculation that depends on two paths from the same source sees
both paths settled.

All declared inputs remain dependencies, even when a callback's `if` expression
uses only some of them:

```roc
display = { show: show_price, price: price, name: name }.Signal.map(
    |value| if value.show { "${value.name}: ${value.price.to_str()}" } else { value.name },
)
```

A price change recalculates `display` even while `show` is false. The resulting
text may be equal, allowing the runtime to stop there.

## Equality stops further propagation

After a calculation, the runtime compares the result with its cached value using
`is_eq`. If they compare equal, that edge does not cause downstream calculations
or UI updates. Source replacements use equality too.

For example, a warning derived from `count > 3` changes when the count crosses
that boundary. Increasing the count from 4 to 5 recalculates the comparison,
but leaves its dependents unchanged.

Builtin values and structural records support equality. For a nominal type
introduced with `:=`, opt into derived equality:

```roc
Tone := [Calm, Warning, Danger].{
    is_eq : _
}
```

A custom comparison must include every distinction downstream code can observe.
If a book's title can change while its id stays the same, comparing only ids
would let the runtime retain the old title. This is a correctness requirement,
as well as a performance consideration.

## Choosing what belongs in state

Store values that cannot be recovered from other current values: an input draft,
a selected item, or whether a panel is open. Derive values such as totals,
validation messages, and button labels from those sources.

A record is useful for fields that form one coherent state transition. Be aware
that every projection of that record depends on the whole record:
`model.map(|value| value.title)` runs when any model field changes. Equality may
stop work after that projection, but it cannot avoid running the projection.

Use separate state sources for independent concerns when that work matters.
Components can accept a named record of signals to preserve those separate
dependencies. An action can update several states together with
`Ui.update_states`; see [State, Events, and Forms](@/docs/state-and-events.md#updating-several-states-together).

## Values and events have different jobs

A signal describes the current value. An event describes something that happened.
Two clicks can mean two refresh requests even when the search text is unchanged.

Use a reducer for a state update. Use `Ui.action` when an event should issue a
command using declared signal reads. Each accepted event invokes the action;
equality of its reads does not suppress a second click.

Use `Ui.on_change` when a command should follow a changed value, such as saving
an edited draft. `Ui.on_change_initial` also runs for the first mounted value.
An action is usually the appropriate choice for Submit, Retry, and Refresh.
[Effects, HTTP, and the Browser](@/docs/effects-and-browser.md) covers these choices.

## State has a lifetime

A **scope** owns mounted state, signals, effects, and rendered structure. Roots,
components, live conditional branches, and keyed list rows establish scopes.
Removing a scope releases its resources and cancels its active work.

Within a scope, structural identity comes from declaration order in the returned
description. List rows also have stable keys supplied by the application.
Reordering a surviving key preserves that row's local state. Removing the key
ends its lifetime; adding it again creates fresh state.

Keep state outside a conditional or list row if it must survive that region's
removal. Hiding a region with a class or attribute keeps its scope and effects
live. [Lists, Conditionals, and Components](@/docs/dynamic-structure.md) explains
how to choose those boundaries.

## Continue with an app

[Getting Started](@/docs/getting-started.md) covers setup. The
[Tutorial](@/docs/tutorial.md) builds a small app, and
[State, Events, and Forms](@/docs/state-and-events.md) provides control and event
examples.
