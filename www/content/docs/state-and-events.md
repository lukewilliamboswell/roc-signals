+++
title = "Local State, Events, and Forms"
description = "State that belongs to one piece of the view: handlers, form controls, validation, derived values, and starting state again."
weight = 5
template = "page.html"
+++

# Local State, Events, and Forms

Local state is what one piece of the view cares about: the fields of a form,
whether a panel is open, the text of a draft. It is created with the piece of
the view around it and goes with it. It needs no entry in the app's store,
and code that has no business with it cannot reach it.

Most of the snippets on this page come from one sign-up form,
`www/samples/state.roc`.

## Introducing state

`State(ctx, s)` is a piece of state as one context sees it. It is read as a
signal and written with reducers. `Engine.state` makes a local one,
`cell.state()` gives a store cell as one, and a table view hands each drawn
row its row as one.

`Engine.state(initial, body)` creates local state and calls `body` with its
`State`. Everything `body` returns can read and write it; nothing outside can.
Each nested state introduces its own context:

{{ sample(file="state.roc", region="states") }}

Inside the inner state, the outer `State` is lifted with `form.lift()` so it
can be used in the inner context. Name the contexts once:

{{ sample(file="state.roc", region="contexts") }}

State inside a list row or a conditional branch is created per row or per
branch, and released with it.

## Handlers

A handler is how an event changes state. For local state it is built from
a `State` and attached to an element:

| Handler | The reducer receives |
|---|---|
| `st.update(f)` | the state |
| `st.update_by(v, f)` | the state and the value `v` reads when the event fires |
| `st.set_value(f)` | the state and the event's payload |
| `st.set_value_by(v, f)` | the state, `v`'s value and the payload |

The handler's declaration chooses its payload kind. For text events, an `input` carries the control's new text, a
`change` on a checkbox or radio carries `"true"` or `"false"`, a `change` on a
select carries the chosen option's value, and a
click or submit carries nothing. `Html` attaches the usual ones for you:
`text_input` and `textarea` listen to `input`, `checkbox` and `select` to
`change`.

`HandlerOf(ctx, p)` is the generic family: `Handler(ctx)` is its text
alias, and `FilesHandler(ctx)` takes the `Received` of a file event. The
same `set_value`, `handle` and `also` serve every payload kind; attaching a
handler through the wrong kind is a compile error.

`update_by` is the tool for "which one": in a list row, `update_by(row.key(), f)`
passes the clicked row's key.

A reducer receives the state's value uniquely owned, so updating a record or
a list in it happens in place. The state is not compared with what it held
before: a reducer that returns an equal value still wakes the state's
readers, and they find nothing to change.

An element takes one handler per event type, whatever its kind or policies;
a second one for the same type is a
contract error. Two things that must both happen are one handler made with
`also` (see [Shared State](@/docs/shared-state.md#local-and-shared-in-one-event)).

Declare browser policies with `Engine.on_with(type, policy, handler)`.
`Policy` has `prevent` and `stop`, both false by default. `prevent` stops
the default action; `stop` hides a bubbling event from page listeners
above the mount root. For an event that does not bubble, `stop` does
nothing, so its target still receives it. Policies are static, chosen
before dispatch; a misspelt field does not compile. Event types are bare
names: retired `:prevent` and `:files` suffixes are contract errors.

## Keys and shortcuts

A key handler receives `Engine.Key`: `key`, physical `code`, `ctrl`, `alt`,
`shift`, `meta`, `repeat`, `composing` and `heard`. Attach it together with
a signal of the chords it hears:

{{ sample(file="keys/main.roc", region="keymap") }}

`Engine.on_key` takes `{ keymap, on, stop }`. Only `keymap` is required;
`on` defaults to `Down` and can be `Up`, and `stop` defaults to false.
Use the ordinary reducers, decisions and `also` at the `Key` payload type.
The old `Html.on_keydown` is removed; text handlers on keydown or keyup are
contract errors naming `on_key`.

`Chord.plain` builds a chord. `with_ctrl`, `with_alt`, `with_shift` and
`with_meta` add modifiers; `primary` gives Ctrl and Cmd alternatives.
`Keymap.prevent(chords)` hears and prevents those chords, while `keep`
hears them with their default intact. `concat` lists the left entries
first. An empty keymap hears nothing and costs no turns. An empty declared chord
is valid but cannot match a browser key.

Ctrl, Alt and Meta must match exactly. ASCII letters compare without case;
Shift must match too, except for a single punctuation or symbol character.
Thus `?` works whether a layout needs Shift for it, while Shift+Tab remains
distinct from Tab. Punctuation and symbols use pinned Unicode 18.0.0 data
in both runners. Space, digits, other letters and named keys compare Shift.

For a shortcut naming an ASCII letter or digit, the physical code is a
fallback when the event's key is not an ASCII letter or digit. Ctrl+K can
therefore work on a Cyrillic layout; Dvorak keeps its labelled ASCII key.
Exact matches anywhere in the list beat every fallback. Compare the
payload's `heard` with your declared chord, rather than repeating these
rules in a handler. It is the original chord that matched.

`Keymap.outside_text()` restricts entries to targets outside text-entry
inputs, textarea, select and contenteditable. It is useful for plain-key
shortcuts such as `/`. `Keymap.every` catches anything no listed entry
matches, including composing keys, and prevents nothing. Named entries
never hear a composing event, so Enter cannot accidentally commit an IME
composition. Concatenation keeps one `every`, heard anywhere if either
side's is.

An unmatched handler is passed over on the way to an ancestor. The nearest
matching local handler wins. `on_document_key` instead hears keys reaching
the document that no local handler of this mount dispatched, including
when focus is outside the root:

{{ sample(file="keys/main.roc", region="shortcuts") }}

The newest mounted matching document handler wins, so a modal can own
Escape and disposal restores the shell's handler. A document handler
cannot compile under a list or table-view row, including within a state
nested in one: it requires the context's `OutsideRows` evidence. There
can be at most 32 live document handlers per instance.

`stop` uses the ordinary propagation policy. At the root it blocks the
document; at the document it blocks window listeners. Other listeners on
the same document still run, in mount order across mounts. A queued event
keeps the keymap match made when it arrived, even if a later batch changes
the keymap before its turn. A handler still decides from its current state.

Browser-reserved chords cannot be prevented, including Chrome's Ctrl/Cmd+N,
T and W, and macOS Cmd+backquote and Cmd+Tab. macOS sends no keyup when a
key is released while Cmd is held; Windows AltGr reports Ctrl+Alt.

A focus trap prevents just the two boundary chords and posts focus commands:

{{ sample(file="keys/main.roc", region="focus-trap") }}

The [Spreadsheet](@/examples/spreadsheet-lite.md) demonstrates navigation,
Shift+Arrow range selection, a changing grid keymap and document shortcuts.

## One event, one transition

A reducer writes one state. If an event must change several things at once —
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

A text box's `value` property is guarded, so the engine can rewrite it
without fighting the user:

- writing the value it already shows does nothing, so the caret stays put;
- a different value is held back while the box has focus or an IME
  composition is in progress, and applied when the box loses focus.

In practice: state written from a keystroke flows straight back, and a value
your app changes while the user is typing (clearing a draft after submit, for
example) appears when focus leaves the box. Checkboxes take `checked` as a
property, and a select re-applies its value when its options change.

For Escape-to-revert, post `ApplyValue(reference)` after restoring the
state. It applies the last rendered value while the control still has
focus, including when equality pruning emitted no new property write:

{{ sample(file="keys/main.roc", region="revert") }}

The reference must name an input, textarea, select or option with an
explicit `Prop.value` (as `Html` controls provide). Otherwise it is a
contract error naming the reference and site. An absent reference counts
stale. During composition the command waits for `compositionend`, so it
does not cut an IME composition. Use it only when replacing the user's draft
is the intended action; ordinary updates keep the guard.

An empty option value remains empty, so `Html.option` can offer an empty
choice such as "All works" without a sentinel value.

`Html` controls set these properties for you. On a raw element use
`Engine.prop` or `prop_s` with `Engine.Prop.value` (text) or
`Engine.Prop.checked` (`Bool`). Properties prune equal values and work in
row templates. An attribute using a name claimed by a property row is a
contract error on that row's elements. Elsewhere, such as on a custom
element, it is only an attribute. A property on an element its row does not allow, or declared
twice, is a contract error at mount. A value property on a file input is
rejected when applied, because its `type` can change through a signal.

## Pointer input and dragging

A pointer handler receives `Engine.Pointer`: its id, kind (mouse, pen,
touch or other), changed button, held-button mask, modifiers, primary flag
and the zone beneath it. Use the ordinary handler constructors at this
payload type:

{{ sample(file="pointer.roc", region="handlers") }}

| Attach function | What it does |
|---|---|
| `Engine.on_pointer(Down\|Move\|Up\|Cancel, handler)` | Deliver every event of that kind |
| `Engine.on_pointer_capture(handler)` | Capture on pointerdown before its turn runs |
| `Engine.on_pointer_paced(handler)` | Report the newest pointermove per pointer at the frame |

`Html` names the same choices `on_pointer_down`,
`on_pointer_down_capture`, `on_pointer_move`, `on_pointer_move_paced`,
`on_pointer_up` and `on_pointer_cancel`. Capture and pacing have their own
attach functions; they are not fields of `Engine.Policy`.

`Html.zone(key)` and `zone_s(signal)` set `Engine.Prop.pointer_zone`.
The nearest zone beneath the actual point gives `pointer.at` as
`In({ zone, x, y })`, with `x` and `y` in 1/10000 of its box: 5000 is
halfway. Outside the mount, over no zone or over a zone with no positive
area gives `Outside`; cancel also gives `Outside`. Empty text turns a
zone off. Capture changes the event's target, while the zone still comes
from the point beneath it.

Interpret the key and fractions with a pure function:

{{ sample(file="pointer.roc", region="zones") }}

Zones provide fractions, so a drop target, splitter or swipe can be pure
Roc logic and run in a native spec. They give no pixels, element sizes or
drag ghost that follows the pointer. Only the nearest zone is reported.

Choose pacing for a drag whose newest position is all that matters;
choose ordinary moves for a stroke that needs every sample. A waiting
move is delivered before an up. The payload is captured when the event
arrives, including its zone and fractions.

Start a drag only for the buttons the app accepts, update its target on
move, and end it on both up and cancel. Put `touch-action:none` on a touch
grip. If a result can dispose the grip during a drag, add up and cancel
handlers on a stable ancestor; the engine cannot know which state a lost
up should reset. The [Kanban board](@/examples/kanban-board.md) keeps its
grip stable, decides the drop in Roc and preserves its Move buttons for
keyboard use. A drop that moves the pressed row ends without a click.

Capture is requested on the declaring element before dispatch. If the
browser refuses it, the handler still runs; the runtime monitor records
`page.captureRefused` and a `pointer-capture-refused` event. Pointer ids
identify active pointers; they are not persistent identities or values
whose numeric choice an app should interpret.

## Derived values

`map` and `map2` compute a value every time something it reads changes. When
the computation is expensive, or many holes read its result, cache it as a derived
signal with `derive`:

{{ sample(file="state.roc", region="derive") }}

`derive` evaluates its input once per change of what it reads. If the
result is equal to the last one, nothing below it runs. Holes that read only
the derived value do no work on a keystroke that leaves it unchanged.

## Starting again

Local state lives as long as the piece of the view that declares it. Often
that is exactly right: a branch that is switched away takes its state with
it. Sometimes the piece stays but what it is about changes, and its state
should not carry over. A draft belongs to the open message, and
opening another message should start a new draft.

`Engine.remount_on(key, body)` builds `body()` and, whenever `key` changes to
an unequal value, disposes it and builds it again. Local state inside starts
again at its initial value:

{{ sample(file="replies/Replies.roc", region="open") }}

The draft has its own state and knows nothing of the remount
around it:

{{ sample(file="replies/Replies.roc", region="reply") }}

- The body takes no argument. It reads the key, if it needs it, like any
  other value.
- An equal key changes nothing: opening the open message again keeps its
  draft.
- The site keeps the key to compare it, so a key should be small, such as an
  id, not the record it identifies.
- Disposing the body follows the rules of every scope: its timers and
  subscriptions stop, and a request still in flight is delivered to the
  remount site, where its write to the state that has gone is skipped.

The sample's spec pins the behaviour:

{{ sample(file="replies/specs/a-draft-per-message.scm", syntax="scheme") }}

## When state stops being local

Local state is the right home until one of these becomes true:

- A second part of the app, somewhere else in the view, needs to read or
  write it. Passing a `State` down through every level between them is what
  the store is for.
- It must outlive the piece of the view that shows it: a draft that should
  survive a change of page, a filter that should survive a branch switching.
- One event must change it together with shared state, and what each becomes
  depends on the same reading.

Then it is a cell of the app's store, and
[Shared State](@/docs/shared-state.md) is the next page.
