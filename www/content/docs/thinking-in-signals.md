+++
title = "Thinking in Signals"
description = "What a signal is, why it replaces re-rendering, and how the model maps to React, Solid, Svelte, Vue, and Elm."
weight = 2
template = "page.html"
+++

# Thinking in Signals

This page assumes you have built web UIs before and have never used a
signals-based framework — or have used one and want to know why this one looks
different. Everything else in these docs is easier after this page.

## Start with the problem

Here is a counter in React:

```jsx
function Counter() {
  const [count, setCount] = useState(0);
  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={() => setCount(count + 1)}>Increment</button>
    </div>
  );
}
```

When you click, React **calls `Counter()` again**. It builds a fresh element
tree, compares it against the previous one, finds that only the text differs,
and updates that text node.

That works, and for a counter it costs nothing. But notice the shape of it: to
discover that one text node changed, the framework re-executed your function and
rebuilt a tree. The work is proportional to *what you re-rendered*, not to *what
changed*. In a large app those two numbers diverge, which is why React gives you
`useMemo`, `useCallback`, and `React.memo` — tools whose purpose is to shrink the
gap between "what I re-ran" and "what actually changed".

React Compiler now automates most of that memoization, which is a real
improvement — but it makes the re-running cheaper rather than removing it. The
model is still: invalidate, re-run, compare.

The re-render model is a **pull** model: something invalidates, and the framework
pulls your code again to find out what the new answer is.

## The signal idea

A signal is a value that changes over time **and knows what depends on it**.

Instead of re-running your code to discover changes, you describe the
dependencies up front. That description is a graph:

```text
   count  ────▶  label  ────▶  <p> text
  (source)     (derived)        (sink)
```

Change `count`, and the runtime walks the edges *out* of `count`: recompute
`label`, then update the text. It never looks at anything else, because nothing
else is connected. This is a **push** model — a change pushes forward along
known edges.

If you have used a spreadsheet, you already know this model. `A1` holds a
number. `B1` contains `=A1*2`. Type a new value into `A1` and the spreadsheet
recalculates `B1` and whatever depends on `B1` — it does not re-evaluate every
cell in the sheet and diff the results. Signals are that, for user interfaces.

The same counter in Roc Signals:

```roc
Ui.state(
    0.I64,
    |count| {
        label = count.signal().map(|n| "Count: ${n.to_str()}")

        Html.section_c(
            "Counter",
            "grid gap-3",
            [
                Html.paragraph_s(label),
                Html.button("Increment", count.on_unit(|n| n + 1)),
            ],
        )
    },
)
```

`Ui.state` introduces a source. `.map` creates a derived node with an edge from
`count`. `Html.paragraph_s` — the `_s` means *signal-backed* — creates a sink
that reads `label`. Three nodes, two edges. Clicking runs the reducer
`|n| n + 1`, then the transform `|n| "Count: ..."`, then one DOM text write.
That is the entire cost, and it stays the entire cost no matter how large the
surrounding app grows.

## Three kinds of node

Everything in a Signals app is one of three things.

**Sources** hold values the host owns and changes: local state (`Ui.state`),
timers (`Signal.interval`), task results, and browser environment values like
`Browser.location()`. You never assign to a source. It changes when an event
fires, a timer ticks, or a request settles.

**Derived nodes** are pure functions of other nodes: `.map`, `.map2`, and the
record-builder form `{ a: signal_a, b: signal_b }.Signal`. They recompute only
when an input changes.

**Sinks** are the places a value reaches the outside world: text
(`Html.text_s`), an input's value, a class, an attribute, `disabled`, `checked`,
whether a subtree is mounted, or a command like "navigate" or "write to
localStorage".

Your job is to model the UI so that the *right things* are sources and
everything else is derived. State that can be computed should never be stored.

## The part that surprises people

**`main()` runs exactly once.**

Not once per event. Not once per state change. Once, at startup. What it returns
is a description, and the host holds onto it forever.

This means every line of your app is in one of three categories, and telling
them apart is the main skill to acquire:

```roc
main = || {
    # CONSTRUCTION — runs once, at startup.
    # Wires up the graph.

    Ui.state(
        0.I64,
        |count| {
            # Still construction. This runs once.

            label = count.signal().map(
                |n| {
                    # RUNTIME — runs every time `count` changes.
                    "Count: ${n.to_str()}"
                },
            )

            Html.button("Increment", count.on_unit(|n| n + 1))
            #                                      ^^^^^^^^^^
            #                                      RUNTIME — runs on each click.
        },
    )
}
```

That example only shows two of the categories. Here is the full picture:

| Category | Where | How often it runs | What it does |
| --- | --- | --- | --- |
| **Construction (once)** | the outer body, and `Ui.state` bodies | exactly once, at startup | builds nodes and edges |
| **Construction (repeated)** | `Ui.when` arms, `Ui.switch` builders, `Ui.each` row renderers, `Ui.component` bodies | every time that scope mounts | builds nodes and edges *again*, for a new scope |
| **Runtime** | `.map` transforms, reducers (`on_unit`, `on_str`, …), `to_cmd` functions | on every relevant change | computes a value; builds no structure |

The middle row is the one that catches people, and it is worth being precise
about because it is the honest limit of "nothing re-renders".

A `Ui.when` arm, a `Ui.switch` builder, and a `Ui.each` row renderer are **construction code that
runs more than once**. Their job is to build fresh nodes, mount fresh state, and
wire fresh edges. Flip a conditional and the losing arm is disposed and the
winning one is constructed. Change a `Ui.switch` case and its old scope is
disposed before the selected builder constructs a fresh one. Add a row and that row's renderer runs, allocating
whatever `.map` nodes it declares.

That is a rebuild — a real one. The difference from a re-render model is *when*
and *how much*: it happens only when structure genuinely changes, never on a
value change, and it is bounded to the scope that changed. A React app re-runs a
component when any of its state changes; here, a `Ui.each` row renderer runs
when that row appears, and never again for the life of the row, no matter how
many times its data changes.

So: value changes are free of construction. Structural changes are not, by
design — that is the escape valve that lets dependency structure vary at all.

The classic mistake is computing at construction time something that should be
derived:

```roc
# Wrong. `full` is a plain Str computed once, at startup.
# It will read "Hello, " forever.
full = "Hello, ${initial_name}"
Html.text(full)

# Right. `full` is a node. It recomputes when `name` changes.
full = name.map(|value| "Hello, ${value}")
Html.text_s(full)
```

The `_s` suffix is your reminder: `Html.text` takes a `Str` and never changes;
`Html.text_s` takes a `Signal(Str)` and tracks it.

## Declared, not discovered

This is where Roc Signals differs from Solid, Vue, and Svelte, and the reason is
worth understanding because it explains the shape of the API.

In Solid, you write:

```js
const doubled = createMemo(() => count() * 2);
```

Solid does not know `doubled` depends on `count` until it **runs** the function
and observes the read. It sets a mutable global "current observer", calls your
closure, and records every signal read while it was running. Dependencies are
*discovered by execution*.

Roc cannot do that. It is a pure language with no mutable globals and no way to
observe its own reads, and this platform is forbidden from changing the
compiler. So Roc Signals inverts it: **dependencies are declared by structure**.

```roc
doubled = count.map(|n| n * 2)
```

The edge `count → doubled` is not discovered by running anything. It is right
there in the call. `.map` *is* the edge. When you need several inputs, name them
with the record-builder syntax:

```roc
totals : Signal.Signal({ price : U64, qty : U64 })
totals = { price: price, qty: qty }.Signal

total_text : Signal.Signal(Str)
total_text = totals.map(|v| "Total: ${(v.price * v.qty).to_str()}")
```

`{ price: price, qty: qty }.Signal` turns a record of signals into a signal of a
record, and declares both edges. Use it instead of reaching for a `map3` or
`map4` — there isn't one, on purpose.

The payoff is that the dependency graph is **an ordinary Roc value**. Your app
hands it to the host once, and the host owns a mutable node table it can update
with push-based propagation. Purity in Roc, mutation in Zig, no compiler magic
anywhere.

### The trade-off, stated plainly

Declared edges are **eager**, not lazy. A derived node subscribes to all of its
inputs for as long as it exists, even inputs it does not currently read.

```roc
# Depends on all three, always — even when `show_price` is false
# and the transform ignores `price`.
display = { show: show_price, price: price, name: name }.Signal.map(
    |v| if v.show { "${v.name}: ${v.price.to_str()}" } else { v.name },
)
```

Change `price` while `show` is false and the host *will* wake this node and run
the transform. The `is_eq` check below then suppresses the output, so no DOM
work happens — but the transform ran. Solid would not have woken it at all.

We accept this because the alternative requires observing reads, which purity
forbids. When dependency *structure* genuinely needs to change, use a scope —
`Ui.when` or `Ui.each` — which builds and tears down whole sub-graphs.
That is the escape valve, and it is the same mechanism that powers dynamic
lists. See [Lists, Conditionals, and Components](@/docs/dynamic-structure.md).

## Equality is the brake

When a derived node recomputes, the host compares the new value to the old one.
If they are equal, propagation **stops there** — dependents are not woken and no
DOM patch is emitted.

That comparison is Roc's `is_eq`. Records, plain tag unions, and builtin types
get it automatically:

```roc
# Fine — structural equality is derived for you.
status = count.map(|n| if n > 3 { TooMany } else { Fine })
```

Opaque types declared with `:=` do not, and you will get a `MISSING METHOD`
error if you use one as a signal value. Derive it:

```roc
Tone := [Calm, Warning, Danger].{
    is_eq : _
}
```

Or write it by hand when the derive is not enough — Conduit's `Session.roc`
spells out the tag-plus-payload comparison for its opaque session union.

Good `is_eq` behaviour is what keeps unrelated parts of the app quiet. It is the
one place where a sloppy definition quietly costs you performance.

## Scopes: where identity comes from

A pure function has no `this` and no allocation identity, so how does the host
know that the `Ui.state` in row #3 of a list is the *same* state it was before a
re-sort?

By **position in the descriptor tree**. When the host walks what your app
returned, it assigns each state binder, conditional, and list an identity from
its construction-order position within its enclosing scope. Scopes are created
by:

- the root,
- each arm of a `Ui.when`,
- each row of a `Ui.each` (keyed by *your* key, not position),
- each `Ui.component`.

Two practical consequences:

**Row state follows the key.** Reorder or filter a list and a surviving row keeps
its local state, because the row's identity is its key.

**Don't make state construction conditional.** Building a different number of
`Ui.state` binders depending on a runtime value shifts the ordinals underneath
them. Wrap the varying part in `Ui.when` or `Ui.component` so it gets its own
scope.

## If you know...

### React

| React | Roc Signals |
| --- | --- |
| `useState` | `Ui.state` — same ordinal-identity constraint as hooks, but scoped (see below) |
| `setCount(c => c + 1)` | `count.on_unit(\|c\| c + 1)` — a reducer attached to an event |
| `useMemo(fn, deps)` | `.map` — always memoized, and the deps can't be *missing* (they can be broader than you need) |
| `useEffect(fn, deps)` | `Ui.on_change_initial(signal, to_cmd)` — runs on mount **and** on change |
| `useEffect` without the mount run | `Ui.on_change(signal, to_cmd)` |
| `useEffect(fn, [])` | `Ui.on_mount(to_cmd)` |
| cleanup function | `Ui.on_cleanup` — but **scope disposal only**, not before each re-run |
| `key` on a list | the key function in `Ui.each` — required, not optional |
| `React.memo` | not needed; no value change causes a re-render |
| conditional rendering with `&&` | `Ui.when` |
| controlled inputs | the same idea: value comes from a signal, events send reducers |
| `useContext` | **no equivalent** — pass signals down explicitly |
| re-rendering a subtree on a value change | **no equivalent** — this is the thing that doesn't exist |

Three of those rows deserve more than a table cell.

**The hooks rule still applies, in a narrower form.** `Ui.state` gets its
identity from construction order, exactly as `useState` does, so the same
"don't declare it conditionally" constraint holds. The difference is scoping:
React has one ordinal space per component, while here every `Ui.when` arm,
`Ui.each` row, and `Ui.component` opens a fresh one. Conditional state is
therefore fine as long as it sits inside its own scope. Be aware there is no
`eslint-plugin-react-hooks` equivalent — nothing warns you.

**Cleanup is not per-change.** React re-runs an effect's cleanup before each
re-execution; `Ui.on_cleanup` fires only when the owning scope is disposed. To
get teardown-and-resetup on a value change, put the effect inside a `Ui.when`
or `Ui.component` scope so the change disposes and remounts it.

**`useMemo` deps can still be too broad.** You cannot forget a dependency, but
`state.map(|v| v.title)` subscribes to the whole record and re-runs whenever any
field changes. `is_eq` suppresses the downstream work; the transform still ran.

The biggest adjustment: your function body is not "the render". It runs once.
Anything that should respond to change must be inside a `.map` or a reducer.

### Solid, Preact Signals, or Angular signals

The model is very close — sources, derived values, fine-grained sinks. The
difference is that Roc Signals has no auto-tracking: `createMemo(() => a() * 2)`
becomes `a.map(|v| v * 2)`, and multi-input derivations use the record-builder
form rather than just reading several signals in a body. Effects are descriptors
returned from your tree rather than calls with side effects.

### Svelte 5 runes

`$state` maps to `Ui.state`, `$derived` to `.map`, `$effect` to
`Ui.on_change`. Svelte's compiler rewrites your code to track dependencies; Roc
Signals asks you to write the edge explicitly instead, because there is no
compiler step to do it.

### Vue

`ref` maps to `Ui.state`, `computed` to `.map`, `watchEffect` to
`Ui.on_change`. Vue's reactivity is proxy-based and implicit; here it is
value-based and explicit.

### Elm

The philosophy is shared — pure description of UI, effects as data, no runtime
exceptions — and Elm is the closest cousin in spirit. The mechanism is the
opposite: Elm rebuilds `view(model)` on every message and diffs it. Roc Signals
keeps a live graph and never rebuilds the view. Your `update` becomes a
collection of small reducers attached directly to the events that trigger them,
and your `Msg` union usually disappears.

## Common misconceptions

**"Signals are just observables / RxJS."** No. A signal always has a current
value — there is no subscription lifecycle, no `.next()`, no completion, and no
time-travel operators. It is a cell in a spreadsheet, not a stream.

**"`.map` is like `List.map`."** Only by analogy. `List.map` runs immediately
and returns data. `Signal.map` builds a node and returns a handle to a value
that will exist later.

**"I can read a signal's current value."** Not in app code. There is no
`signal.get()`. If you need a value, you are inside a `.map` or a reducer, where
the host hands it to you. This is deliberate: an unrestricted read would be an
undeclared edge.

**"State updates are asynchronous, like `setState`."** They are not batched
across your code the way React batches. A reducer runs, the graph propagates,
patches are emitted.

## Next

You now have the model. Next: [Getting Started](@/docs/getting-started.md) to
install and run something, or jump straight to the
[Tutorial](@/docs/tutorial.md) to build an app one concept at a time.
