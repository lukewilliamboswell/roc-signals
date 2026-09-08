+++
title = "Native GUI"
description = "Build native examples with typed controls, explicit signals, and scoped structure."
weight = 12
template = "page.html"
+++

# Native GUI

The native platform runs the same Signals engine behind GPUI. Application state,
commands, equality pruning, keyed rows, and scope disposal use the APIs described
in [State, Events, and Forms](@/docs/state-and-events.md) and
[Dynamic Structure](@/docs/dynamic-structure.md). Import `pf.Gui` for native
controls. The current target is Linux x86_64 with glibc and a Wayland/GPU session;
see [contributing](@/docs/contributing.md#native-gui-platform-spike) for the pinned
compiler, host build, executable build, and test commands.

## Controls and layout

`Gui.row`, `Gui.column`, and `Gui.panel` take an attribute list followed by a
child list. `Gui.style` accepts a complete record based on `Gui.style_default`;
`Gui.style_s` changes that record through normal signal propagation. Each element
accepts one style. A supplied style replaces the control's defaults, so include
padding or borders explicitly when you want them.

Styles specify logical-pixel dimensions, spacing, padding, colors, borders,
radius, font size, and overflow. Lengths are `Auto`, `Fill`, or `Px(value)`;
colors are `Default` or `Rgb(value)`. Zero font size and default colors inherit.
These are native presentation properties. Semantic labels, test IDs, selected
state, and enabled state are separate attributes.

| Control | Inputs |
| --- | --- |
| `heading`, `text` | literal string |
| `text_s` | string signal |
| `button` | label and unit message |
| `action_button` | `{ label, enabled }` signals, attributes, unit message |
| `text_input`, `textarea` | `{ label, value }`, attributes, string message |
| `checkbox` | `{ label, checked }`, attributes, boolean message |

Text controls are controlled: their value comes from a signal and committed
edits enter the corresponding message handler. Native editors retain selection,
clipboard behavior, and IME preedit locally. `textarea` preserves hard line
breaks; soft wrapping is not implemented. Text input is bounded at 1 MiB.
`Gui.enabled_s` and `Gui.disabled_s` change availability while preserving the
control's identity.

Use `Gui.test_id` for stable spec locators and `Gui.label` for semantic names.
Labels do not establish native screen-reader support, which is not implemented.

## Wide lists

`Gui.virtual_list({ row_height, follow_tail }, attrs, children)` lays out only
the visible child range. Give every direct child the same fixed logical height;
`row_height` must be between 1 and 16,384. Use `Ui.each` for keyed child rows.
`follow_tail` is a boolean signal that keeps the final row visible as history
changes when enabled.

Virtualization bounds native child lookup and layout work. Reactive row scopes
remain mounted, so the application still owns its data retention policy. The
Activity Monitor example caps its simulated history at 1,000 entries. Ordinary
containers enumerate their direct children when rendered; choose the virtual
list for a wide collection.

## Keyboard regions

`Gui.on_shortcut(chord, message)` binds a unit message within a focused region.
A chord is `{ key, control, shift, alt, meta }`, with every modifier explicit.
Use lowercase letters, digits, or named keys: `enter`, `escape`, `tab`, `space`,
`left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `backspace`,
`delete`, and `f1` through `f12`. Matching is exact. The nearest matching ancestor
receives the event; native text-editing actions take precedence.

A region accepts at most 32 shortcuts. Duplicate chords are errors. Registrations
belong to their element's scope and stop receiving events after disposal.
See `test/gui/shortcuts` for a complete app and scoped routing spec.

## Example coverage

The collection in `examples-gui/` exercises platform features through ordinary
application workflows. `counter` is the minimal starting point; `keyed-rows`
shows retained row drafts and scoped structure. `notes-editor` exercises native
multiline editing, and `activity-monitor` uses bounded deterministic replay,
filtering, selection, and a virtual list. Its events are simulated operations,
not measurements of your machine.

Every registered app has native semantic specs. The GUI suite also runs GPUI
adapter tests with simulated input and layout. A Wayland smoke run checks the
linked renderer and adapter; an actual pointer, keyboard, and IME walkthrough
remains a separate form of validation.
