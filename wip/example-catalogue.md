# Example Gallery Catalogue

A proposed catalogue of realistic small-to-medium apps for the Roc Signals
gallery, chosen so that each one *has* to use a signals-shaped solution rather
than merely being written on top of one.

## Why the current gallery under-sells the model

An audit of API usage across the eleven public examples:

| Example | Lines | Signal API used |
| --- | --- | --- |
| json-config-editor | 93 | `Ui.state` only |
| workspace-widgets | 117 | `Ui.state`, `each_str`, `component` |
| command-palette | 141 | `Ui.state` only |
| live-search | 161 | `interval`, `fold_task`, `cleanup`, `online` |
| api-request-console | 172 | `fold_task`, full `Http` |
| team-signup | 208 | `Ui.state`, `const` |
| deployment-queue | 222 | `Ui.state`, `when`, `each_str` |
| team-checkout | 629 | `Ui.state`, local storage |
| release-planner | 1010 | `each_str`, one `Ui.state` |
| service-ops-center | 2372 | broad: routing, interval, http, visibility |
| conduit | 3864 | broad: routing, http, storage |

Three problems fall out of that table:

1. **`Signal.map`, `map2`, and `combine` are essentially absent** (one use of
   `map` in all of conduit, zero uses of `map2`/`combine`). Derived values are
   the entire point of a signal graph, and the gallery never shows a diamond
   dependency, a fan-in, or a chain deeper than one hop.
2. **State is monolithic.** `release-planner` is 1010 lines behind a *single*
   `Ui.state`. That reads exactly like a `useReducer` app, so a visitor
   concludes signals are a rendering detail rather than a state model.
3. **Nothing is big enough to feel the update granularity.** No example renders
   a list where a per-row update visibly avoids touching siblings, which is the
   headline claim of fine-grained reactivity.

The catalogue below is organised so every group closes one of those gaps.

---

## Group A — Derived state and the dependency graph

The pitch: *state you never store because it is computed*.

### A1. Split-the-Bill / Expense Settler
Small. A trip expense splitter: people, expenses, shares, and a settlement plan
("Ana owes Bo $42").

Showcases: a genuine dependency diamond. `people` and `expenses` fan into
per-person balances, which fan into the minimal-transfer settlement. Editing one
share amount recomputes exactly one balance pair and one settlement row.

Signals surface: `map2`, `combine`, chained `map`, keyed `each_str`.

### A2. Unit-Aware Recipe Scaler
Small. Scale a recipe by servings or by a target pan size, with unit conversion
and "you need to buy" aggregation across several recipes.

Showcases: one input (servings) driving dozens of independent derived leaves.
Ideal for a side-by-side "what recomputed" visualisation.

### A3. Loan / Mortgage Comparator
Small–medium. Two or three loan scenarios side by side, an amortisation table,
and a break-even point.

Showcases: an expensive derived value (the amortisation schedule) that must be
memoised per-scenario, plus a cross-scenario comparison signal. This is the
clearest place to show that a derived signal recomputes once, not once per
reader.

### A4. Spreadsheet-Lite
Medium. A 20x10 grid where cells hold literals or `=A1+B2*2` formulas.

Showcases: the canonical fine-grained-reactivity demo. A spreadsheet *is* a
signal graph; the formula parser builds the dependency edges. Also demonstrates
cycle detection and error propagation (`#REF!`, `#DIV/0!`) through the graph.
This is the single strongest showcase app in the catalogue and worth building
even if nothing else on this list is.

---

## Group B — Async, staleness, and the network

The pitch: *async state as a value, not a lifecycle*.

### B1. Package Registry Explorer
Medium. Search a package registry, open a package, browse versions and
dependencies, with a back/forward-correct URL.

Showcases: latest-wins search, per-panel independent loading states, and a
request that is cancelled by navigation. Extends `live-search` into something
with real depth. (`task-latest-wins` already exists as a fixture — this makes it
an app.)

### B2. Flight / Booking Search
Medium. Filters (dates, stops, price, airline) over a result set, where changing
a filter refetches, and changing a *sort* does not.

Showcases: the distinction between a derived view (sort, local filter) and an
effect trigger (refetch). Getting this wrong is the most common signals mistake,
so an example that gets it right is didactic.

### B3. Offline-First Field Notes
Medium. Capture notes while offline, queue mutations, sync on reconnect, show
per-item sync status.

Showcases: `Browser.online`, local storage as the source of truth, an outbox
signal, and optimistic UI with rollback. Currently no example combines storage
with async at all.

### B4. Status Page / Incident Timeline
Small–medium. Poll a set of service checks, roll them up into an overall status,
render an incident timeline.

Showcases: `interval`-driven refresh throttled by `Browser.visibility`,
fan-in from many independent task signals into one derived rollup. Narrower and
more approachable than `service-ops-center`.

---

## Group C — Scale and update granularity

The pitch: *a big list that stays cheap*.

### C1. Log Viewer with Live Tail
Medium. A streaming log pane with level filters, a text query, follow-tail
toggle, and highlighted matches.

Showcases: high-frequency appends where only the tail mutates. The most visceral
demo of fine-grained updates; pair it with a DOM-mutation counter in the UI.

### C2. Virtualised Data Grid
Medium. 10k rows, sortable columns, inline editing, multi-select, a sticky
summary row.

Showcases: keyed lists at a scale where reconciliation strategy matters, plus a
summary that aggregates the full dataset while only visible rows are rendered.
Also serves as a performance regression target for the engine.

### C3. Kanban Board
Medium. Columns, cards, drag between columns, WIP limits, per-column counts,
filters.

Showcases: keyed list reordering across containers — the hardest case for any
diffing strategy — and per-column derived counts that must not recompute the
whole board.

### C4. Gantt / Dependency Scheduler
Medium. Tasks with dependencies; moving one task cascades dates through its
dependents; critical path is highlighted.

Showcases: a user-authored dependency graph mapped onto the signal graph, so the
propagation the engine does is the propagation the domain needs. A natural
successor to `release-planner` with the state actually decomposed.

---

## Group D — Editors and bidirectional state

The pitch: *many views of one value, all consistent*.

### D1. Markdown Editor with Live Preview and Outline
Small–medium. Editor pane, rendered preview, table of contents, word count,
reading time.

Showcases: one source string feeding four independent derived views at different
costs. Uses the existing `markdown-elem` support.

### D2. Form Builder
Medium. Drag fields into a form, edit each field's validation rules, and see a
live preview of the generated form — which itself validates.

Showcases: a two-level signal graph (the builder's state produces a form whose
own state is reactive). This is the "signals compose" argument made concrete.

### D3. Query Builder / Filter Composer
Small–medium. Build a nested AND/OR filter tree visually; show the generated
query and a live matching-row count.

Showcases: a recursive component over a tree signal, with a derived value
(match count) computed over the whole tree on each edit.

### D4. Theme / Design Token Editor
Small. Edit tokens; every preview component updates; export CSS.

Showcases: one token change touching hundreds of bindings without a re-render,
plus derived contrast-ratio validation per token pair.

---

## Group E — Time, coordination, and multi-pane state

### E1. Pomodoro / Time Tracker
Small. Timers per project, running totals, daily rollup, persistence across
reload.

Showcases: `interval` as a first-class signal, a derived elapsed value, and
cleanup on unmount. Small enough to be a "second example" after the counter.

### E2. Calendar / Availability Picker
Medium. Week view, timezone selection, availability slots, conflict detection.

Showcases: derived timezone conversion across every rendered slot from a single
signal, and conflict detection as a fan-in over slot pairs.

### E3. Multi-Step Wizard with Save-and-Resume
Medium. A multi-page onboarding/application flow with per-step validation, a
progress signal, cross-step dependent fields, and draft persistence.

Showcases: validation as derived state rather than an event handler, and a
"can I submit" signal that fans in from every step. Extends `team-signup` and
`team-checkout` into one coherent app.

### E4. Chat / Support Inbox
Medium. Conversation list, thread pane, typing indicator, unread counts,
optimistic send.

Showcases: two panes derived from one store, unread counts that update without
re-rendering threads, and polling merged with local optimistic state.

---

## Suggested build order

If the goal is maximum showcase value per unit of effort:

1. **A4 Spreadsheet-Lite** — the definitive signals demo; nothing else argues
   the case as directly.
2. **C1 Log Viewer** — cheapest high-impact performance story.
3. **A1 Split-the-Bill** — small, readable, and the best teaching example for
   derived state.
4. **C3 Kanban** — stresses keyed reconciliation, familiar to everyone.
5. **B2 Flight Search** — teaches the derived-vs-effect distinction.
6. **D1 Markdown Editor** — small, visual, good landing-page screenshot.
7. **E1 Pomodoro** — natural second tutorial example.

Everything else is worth having but is a variation on a case those seven already
make.

## Cross-cutting suggestions

- **Refactor `release-planner`** to decompose its single `Ui.state`. As written
  it is an argument *against* the model.
- **Annotate each example** in the gallery with the concepts it demonstrates, so
  a visitor can navigate by "I want to learn X" rather than by app name.
- **Add a "what updated" overlay** as an opt-in dev mode. The strongest claim of
  the framework is currently invisible in every example.
- **Keep a size ladder**: at least three examples under 120 lines, so the gallery
  does not read as "you must write 1000 lines to do anything".
