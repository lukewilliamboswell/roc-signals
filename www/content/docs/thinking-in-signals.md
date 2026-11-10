+++
title = "Thinking in Signals"
description = "Sites, values, layers and turns: the model behind every Roc Signals app."
weight = 2
template = "page.html"
+++

# Thinking in Signals

A Roc Signals app is a description. Your Roc code builds a tree of elements
once, at mount, and the engine keeps that tree alive and up to date. This page
explains the handful of ideas that description is made of.

## Static structure and dynamic sites

Most of a UI never changes: a heading, a form's layout, a button's label.
`Engine.element`, `Engine.text` and the `Html` helpers describe that structure,
and the engine creates it once.

The parts that can change are *sites*. A site is one of:

- a **state** (`Engine.state`), which holds a value the user can change;
- a **derived value** (`Engine.derive`), which holds a value computed from
  others;
- a **conditional** (`Engine.when`, `Engine.switch`), which shows one branch;
- a **keyed list** (`Engine.each`), which shows one row per item;
- a **component** (`Engine.component`), a reusable piece with its own inputs
  and outputs;
- an **effect** (`Engine.watch`, `Engine.on_change`, `Engine.on_cleanup`),
  which asks the outside world to do something.

Between them sit *holes*: text and attributes whose content is a value.

## Values declare what they read

A `Val(ctx, a)` is a value of type `a` that can change. You get one from a
state (`count.val()`), from a row (`row.field(...)`) or from a constant
(`Engine.const(...)`), and you transform it with `map` and `map2`:

{{ sample(file="state.roc", region="map2") }}

A value carries the set of states it reads. The engine never runs your code to
find out what it depends on: it knows from how the value was built. When a
state changes, the engine re-evaluates exactly the holes and sites whose values
read it.

That knowledge is conservative. A value built from `map2(a, b, ...)` reads both
`a` and `b`, even if your function only looks at `b` when `a` is true. The cost
is an extra evaluation, never a wrong answer.

## Equal values stop the work

Every hole remembers the last value it put on the page. If a re-evaluation
produces an equal value, nothing is emitted and nothing below it runs. The same
holds for a row whose item did not change, a derived value that came out equal,
a conditional whose branch did not change, and an effect whose watched value
did not change.

So a keystroke that changes a name re-evaluates the holes that read the name,
and the page sees one text update. Everything else stays untouched.

## Handlers and turns

A handler is a reducer over one state, attached to an event:

{{ sample(file="counter/Counter.roc", region="view") }}

When the user clicks, the engine runs one *turn*:

1. It finds the handler from the clicked element.
2. It applies the reducer to the state's current value.
3. It refreshes every hole and site that reads that state, in order from the
   outside in.
4. It returns one batch of DOM commands, which the runtime applies.

All writes of a turn happen before anything observes them, so no text ever
shows a half-updated state. An effect result, such as an HTTP response, enters
the same way: it is one turn, running the reaction you gave the request.

## Contexts

Every value, handler and element is typed by the context it lives in. A state
of type `s` introduces the context `In(outer, s)`; a list row introduces
`Row(outer, item)`; a component introduces `Comp(prop, action)`.

{{ sample(file="state.roc", region="contexts") }}

A value from an outer context is brought inward with `lift` (or `lift_row`
inside a row). Naming contexts with type aliases, as above, keeps annotations
short. Contexts are why a value can only be read where it exists, and why the
engine can route an event to its state without searching.

## Scopes

A conditional's branch, a list's row and a component are *scopes*. Everything
mounted inside one — its state, its rows, its timers and subscriptions — lives
exactly as long as the scope. When a branch switches or a row's key leaves the
list, the engine removes its DOM nodes, releases its state and cancels its
subscriptions, timers and worker runs. HTTP requests and storage reads already
in flight are not lost: their results go to the nearest surviving scope. [Lists, Conditionals, and
Components](@/docs/dynamic-structure.md) covers identity and lifetime in
detail.

## Keep separate concerns separate

Because reads are declared per state, the shape of your state decides how much
work an update does. One big record read by every hole re-evaluates every hole
on every change. Put independently changing concerns in independent states,
compute expensive views once with `derive`, and keep row-local state inside the
row. [Structuring an App](@/docs/app-architecture.md) shows the pattern.
