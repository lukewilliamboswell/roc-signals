# Native GUI presentation boundary

The statically linked GUI boundary uses protocol version **4**. Zig exports
`signals_protocol_version` and `signals_node_size`; Rust checks both before
mount. Version 4 adds the typed shortcut accessor to version 3's indexed child
queries and virtual-list metadata. Both sides must be rebuilt together.
The browser protocol and its version are unchanged.

`Gui` lowers native presentation through the shared scalar descriptor machinery.
Text field **8** is `native_style`, field **9** is `native_viewport`, and boolean
field **4** is `selected`. The unused
IDs 7 and 3 remain the existing custom text/bool field markers. Native fields
are explicit protocol fields, not CSS, class names, test identifiers, or custom
attribute conventions. The browser rejects them before reserving or staging a
command batch. Native specs retain them through the ordinary render publication.
The native context also prepares a browser-shaped journal for shared structural
bookkeeping; these native fields publish only through its typed native
publication and never acquire invented browser opcodes.

The style field contains a canonical ASCII decimal record separated by commas:

```
version,direction,gap,padding,width_kind,width,height_kind,height,grow,background,foreground,border_color,border_width,radius,font_size,overflow_x,overflow_y
```

Version 1 has exactly these 17 fields. Numbers have no signs, whitespace, or
leading zeroes. Direction is row=0 or column=1. Length kind is auto=0, fill=1,
pixels=2; auto/fill must have a zero value. Grow is 0 or 1. Overflow is
visible=0, clip=1, scroll=2. Colors are 24-bit RGB or 16777216 for inherited/default.
Lengths, spacing, radius, borders, and font size are logical pixels, bounded at
16384. Font size zero inherits. Invalid records are programmer-contract errors,
not a request to substitute defaults. Records are bounded at 192 bytes.

The public `Gui.Style` contains typed lengths, colors and overflow tags. Only the
platform encoder creates records. `Gui.row`/`column`/`panel` choose direction;
`Gui.style` and `style_s` describe the remaining fields. Each element accepts one
style attribute. A supplied style replaces the helper's complete default style.
The style signal is an ordinary typed, equality-pruned signal; there is no
native styling observer graph.

Zig validates the style during native publication preparation and exports an
`extern` struct of 16 `u32` fields in the order after `version` above. Rust copies
this validated record along with primitive fields and borrowed UTF-8 data before
any next engine operation. Rust applies the supplied layout and presentation
properties with GPUI. Selected state adds the standard selection border, and
disabled state applies reduced opacity and refuses input dispatch.

`signals_dispatch` accepts event ID, payload kind, UTF-8 pointer/length, and a
boolean word. Kind 0 is unit, kind 1 is text, kind 2 is checked boolean; boolean
payloads require zero text bytes and a value of 0 or 1. Unit payloads require
zero text bytes and a zero boolean word; text payloads require valid UTF-8 and
a zero boolean word. Each kind uses the shared
engine's existing event extraction descriptor and capability-owned reducer path.
Deferred callbacks validate both node identity and current binding, and cannot
update disposed or rebound controls.

`Gui.on_shortcut` adds a typed `key_chord` filter to the canonical shared event
binding. It always uses a unit `keydown` route with native delivery and static
prevent-default/stop-propagation policy. Filter identity is the complete key and
modifier record; event identity still comes from construction within the owning
scope. Duplicate chords are errors, and each element accepts at most 32. The
browser rejects these filters during descriptor collection and again before wire
staging. The native publication retains them without inventing browser opcodes.

The public `Gui.KeyChord` record has `key: Str` and four boolean fields:
`control`, `shift`, `alt`, and `meta`. Keys are lowercase `a`–`z`, digits `0`–`9`,
or `Enter`, `Escape`, `Tab`, `Space`, `ArrowLeft`, `ArrowRight`, `ArrowUp`,
`ArrowDown`, `Home`, `End`, `PageUp`, `PageDown`, `Backspace`, `Delete`, and
`F1`–`F12`. Uppercase letters, key aliases, and chord strings such as `ctrl-s`
are rejected. Modifiers match exactly; extra modifiers do not match.

`signals_read_shortcuts(element, output, capacity)` copies committed registrations
into caller-owned storage after checking capacity. Each record contains an event
ID (`u64`), key code (`u32`), and modifier mask (`u32`). Letter/digit codes are
ASCII; named keys use 256 upwards in the order listed above. Modifier bits are
Control=1, Shift=2, Alt=4, Meta=8. The function allocates nothing and enters no Roc
code; Rust retains a copy bounded at 32 records per element.

GPUI first dispatches a focused control's editing bindings. Unhandled keys then
bubble through the focused region and its ancestors; the nearest matching live
shortcut dispatches one ordinary engine event and consumes the keystroke. Native
selection, clipboard, movement, and newline keys keep their editing behavior.
Clicking a shortcut region makes it focusable without stealing focus from a
focused child. A listener whose element was disposed, disabled, or rebound does
not dispatch or consume the keystroke. Removing a region releases its shortcuts
through ordinary scope disposal and releases the corresponding retained view.

Native editors accept at most one MiB of UTF-8 text, matching the ingress and
Files read limits. An oversized user insertion, paste, or IME replacement is
refused in full before changing text, selection, or composition; it emits no
engine event. Deleting or replacing a selection can make room for a later edit.
Oversized authoritative application values remain contract errors.

Input labels are both visible captions and semantic metadata. Semantic roles,
names, and test IDs support native specs and GPUI test selectors. They do not
establish Linux screen-reader support: the pinned GPUI dependency does not expose
an operating-system accessibility tree.

`Gui.virtual_list({row_height, follow_tail}, attrs, children)` presents direct
children at a fixed logical height. `Ui.each` retains its ordinary key and scope
semantics; scrolling changes GPUI layout work, not which reactive scopes exist.
The `native_viewport` field is a separate canonical record
`1,row_height,follow_tail`: height is 1–16384 and follow-tail is 0 or 1. The record
is bounded at 32 bytes. Rust receives two validated `u32` fields, both zero when
the viewport field is absent. An ordinary style update does not remove viewport
metadata.

The live GUI executor applies already-decided child edits to a prepared indexed
order, sharing the engine's order-index implementation while keeping element
and row identities distinct. Sparse edits copy changed index paths; full
snapshot replacement explicitly visits the replaced child set. Failure during
preparation leaves the prior order intact. Publication allocates nothing, and
empty or removed parent indexes are retired. The native semantic spec runner
continues to retain its observed DOM representation.

`signals_read_changed` exports a child count rather than a child pointer.
`signals_child_at(parent, rank)` returns one committed child in logarithmic
expected time; invalid ranks and calls outside the mount lifetime are contract
errors. The UI thread cannot interleave propagation while consuming a render
range. No viewport request scans preceding siblings, copies a full child list,
or changes application state. Rust retains node entities and renders only the
requested viewport range; ordinary containers enumerate their direct children
when they render. Fixed-height row caches preserve retained subtree identity.

Follow-tail positions the final matching row at the bottom when the list is
updated while enabled. Turning it off leaves scrolling under user control.
This is presentation policy, not a second timer, observer, or reactive graph.

## Native Files and task transport

`Files` declares native chooser, read, write, and recursive scan tasks. Each
factory takes a diagnostic label; the label never selects host behavior.
`Node.TaskKind` is an explicit closed route: external=0, choose-file=1,
choose-directory=2, choose-save-path=3, read-text=4, write-text=5, scan-directory=6.
The browser rejects non-external task routes before command publication. Its
existing task command wire format is unchanged.

Task declarations own separate initializers for cancellation and capacity
refusal. `Signal.cancel(task)` publishes the declared terminal error and retires
the pending request in one shared source transaction. Canceling an already
settled task has no effect. Saturation publishes the declared refusal value and
supersedes older work for that source. Files uses `Error.Canceled` and
`Error.ResourceLimit`. Neither case invokes a failure decoder with invented text.
Scope disposal cancels without creating a new application-visible value.

The separate native effects boundary is version **1**. Rust checks
`signals_effect_version()` and `signals_effect_size()` before mount.
`signals_effect_next(out)` returns zero when empty or one after writing an
`extern` record: `op: u32`, `kind: u32`, `id: u64`, and request pointer/length.
Start has op=1 and an explicit kind; cancel has op=2, kind=0, and an empty request.
The UI thread copies request bytes before the next engine call. Results enter
through `signals_task_result(id, failed, pointer, length)`, where failed is zero
or one and text is strict UTF-8. No Roc value, callable, layout, or pointer leaves
the engine thread.

The host reserves at most **16** operations, including queued work, running work,
canceled workers, and completed results awaiting UI-thread delivery. It reserves
and copies requests before engine commit; publication allocates nothing. A queued
request canceled before dispatch releases immediately. A running request retains
its reservation until completion; late canceled results are rejected before any
Roc decoder runs. Result commit releases the reservation before observers launch
follow-up work. Rust only schedules copied primitive work and returns results;
identity, scope lifetime, replacement, and propagation remain in the engine.

GPUI dialogs use the desktop portal. Explicit cancellation invalidates result
delivery; the pinned GPUI API provides no handle for closing an already open
dialog, so its receiver keeps a reservation until the dialog actually settles.
Closing the host invalidates worker flags and callbacks before engine teardown.
Workers check cancellation between bounded chunks or entries; a blocked operating
system call can delay completion. Capacity remains bounded during that delay.

Files uses a strict private `files1` codec. Each frame is a canonical decimal UTF-8
byte length, a colon, and exactly that many bytes. Every packet begins with the
frame `6:files1`, has at most **8 MiB**, and has no trailing fields. Lengths have
no signs or leading zeroes. Native publication validates request framing before
publishing work; both adapter and Roc result decoder reject malformed packets.
Task kind defines the remaining request frames:

| Kind | Request frames |
| --- | --- |
| Choose file / directory | none |
| Choose save path | location kind (`home` or `at`), directory, suggested file name |
| Read text / scan | absolute path |
| Write text | absolute path, complete UTF-8 text |

Choice results are `chosen, path` or `canceled`. A user dismissing a dialog is
`Done(Choice.Canceled)`; explicit task cancellation is `Failed(Error.Canceled)`.
Read results are `path, text`; write results are `path, byte count`; scan results
are `root, entry count` followed by `path, kind, bytes` for each entry. Entry kinds
are `file`, `directory`, `symbolic-link`, and `other`. Errors have `code, detail`;
codes are `canceled`, `not-found`, `permission-denied`, `invalid-utf8`,
`invalid-path`, `resource-limit`, `io`, and `unavailable`.

`choose_save_path` takes `{directory: [Home, At(Str)], suggested_name: Str}`.
`Home` resolves the native environment's UTF-8 `HOME`; a missing or non-UTF-8 value
returns `Unavailable`. `At` supplies an explicit initial directory. Both paths
must be absolute and valid. In the private request record `home` requires an
empty directory frame; `at` carries the supplied path. No empty-path convention
is exposed to applications.

Paths are absolute UTF-8, at most **4096 bytes**; invalid paths and unsupported
traversal return typed errors. Text reads and writes are bounded at **1 MiB**.
Scans return one complete snapshot of at most **10,000 entries**, **64 levels**,
and **4 MiB of aggregate entry paths**. Symlinks and other entries are reported
without traversal. Limits refuse the entire operation instead of truncating it.
Writes create a temporary sibling, write the immutable submitted text, and rename
it into place. Failure or cancellation before commit removes the temporary file;
cancellation cannot undo a rename that has already committed.
