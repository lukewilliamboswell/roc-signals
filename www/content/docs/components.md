+++
title = "Components"
description = "A component is a type module: a type, its pure operations, and a view that is handed the cells it uses and names no app's store."
weight = 9
template = "page.html"
+++

# Components

Roc organises code around types: a module defines a type and the functions
on it. A component is that kind of module with a view added. It is not a
special construct of the engine, which mounts the elements a view returns
and knows nothing else about it.

The snippets come from the cart of the shop in
[Shared State](@/docs/shared-state.md), `www/samples/shop/Cart.roc`.

## The smallest component

A function over what it is handed is already a component. This one is handed
a `State`:

{{ sample(file="structure.roc", region="over-a-state") }}

The caller decides whose state it is: a local state
(`Engine.state(3, stars)`), a row of a table, which a table view hands out as a
`State`, or a cell of the store (`cell.state()`).

## A type and its operations

A component with state of its own starts as an ordinary type module. The type
is the component's state, and every change to it is a pure function on the
type:

{{ sample(file="shop/Cart.roc", region="type") }}

`::` makes the type opaque: other modules hold a `Cart` and call its
functions, and cannot build one or take one apart by hand. The operations
are tested where they are written, with no engine and no browser:

{{ sample(file="shop/Cart.roc", region="expects") }}

One thing to know when naming things in a type module: its own functions
are in scope throughout its block, and Roc does not allow shadowing. A
parameter or a local that reuses the name of a function defined above it
is reported as a duplicate definition. That is why the cart's row function
below is `line_row`: `line` stays free for the lambdas that walk the lines.

## The view is handed its cells

Shared state reaches a component as a props record of cells. The record says
exactly which shared state the component reads and writes:

{{ sample(file="shop/Cart.roc", region="cells") }}

The view takes that record and is generic twice over: in `st`, the type of
whichever store holds the cells, and in `ctx`, the context it is drawn in.

{{ sample(file="shop/Cart.roc", region="view") }}

Because the view names no store and no fixed context, it works at any depth, in a
row, and in another app. `Props(st)` takes the store's type as a parameter because
a type alias cannot leave it to the compiler with `_`.

## Private state stays local

What only the component cares about is local state in its view. The cart's
panel is open or closed, and no one else reads that, so it is an
`Engine.state` and not a cell. It needs no entry in the store, cannot be
reached by code that has no business with it, and starts again by itself
when the cart's piece of the view is disposed.

Inside, the component writes its cells with decisions, from any depth, and
composes them with its local writes:

{{ sample(file="shop/Cart.roc", region="contents") }}

## A feature describes its own cells

`Cart.cells({})` above is the description of the cells a cart needs, with a
reset where they should start again. The app nests it in its store as one
field, and gets back the cells in the shape the component chose. A cell
the component gains later appears in the app's store, and in the reset,
with no change to the app.

## Only the composing module imports the store

The store's description names the component's type, so the module that
builds the store imports the component. A component that imported the store
back would make the two import each other. So a third party hands the
component its cells: the module that composes, a page or the app's root.

{{ sample(file="shop/Shop.roc", region="view") }}

In this small app the root both builds the store and composes. In a larger
one the store has a module of its own, each page composes its components, and
the components import neither. Passing is one level deep: a cell needs
nothing to reach a nested context, so a component hands a cell to a child
directly and nothing is threaded through the contexts between.

## Nothing is sent upward

There is no action type and no channel from a component to its owner. A
component that must tell the rest of the app something does one of two
things:

- It writes a cell it was handed, in the same decision as its own change.
  The cart's rows write the cart's cell, and the shop's product rows and its
  check-out read it.
- It runs a handler or a reaction it was handed, composed with its own by
  `also`. A menu that closes itself, which is its own state, and then runs
  the handler its owner gave it is `open.update(...).also(chosen)`.

What a component needs from above arrives as ordinary values in its props:
values, cells, an element to place, a handler.

## What the types do not catch

A component handed the wrong cell of the right type compiles: two
`Cell(st, Str)` are the same to the type checker. A spec, or a pure test of
the transition, is what tells them apart. Keep a component's props to the
cells it uses, and name them for what they hold.

## Code size

A view that is generic over its context is compiled once for each kind of
context it is drawn in. That is what lets one view read the store and be drawn
in a row with no ceremony. Its price is code size: a large view drawn under
several kinds of context is in the module once for each.
