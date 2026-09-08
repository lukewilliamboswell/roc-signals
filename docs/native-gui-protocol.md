# Native GUI presentation boundary

The statically linked GUI boundary uses protocol version **5**. Zig exports
`signals_protocol_version` and `signals_node_size`; Rust checks both before
mount. Version 5 adds an element lifetime, borrowed drag key, and drop event ID
to the node record. Both sides must be rebuilt together.
The browser protocol and its version are unchanged.

`Gui` lowers native presentation through the shared scalar descriptor machinery.
Text field **8** is `native_style`, field **9** is `native_viewport`, field **10**
is `native_drag_key`; boolean fields **4** and **5** are `selected` and
`native_drop_target`. The unused
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

Internal drag sources expose a nonempty UTF-8 key of at most 256 bytes through
`Gui.drag_source`. `Gui.drop_target` binds an ordinary native `drop` event with a
string-detail extraction descriptor. The target flag requires that binding;
invalid keys or payload shapes reject preparation before publication. Both
native scalar fields are rejected by the browser boundary.

Rust copies the key into the drag along with source element, view, runtime, and
lifetime guards. It checks both source and target at hover and again at drop,
including current enabled state and binding. The engine advances a checked
lifetime counter on descriptor retirement, even when the same element identity
is reused in that transaction. Disposed, replaced, rebound, disabled, or foreign
sources and targets cannot deliver a stale drop. Accepted drops enter ordinary
engine propagation as string detail. The key is application data, never an
identity derived from content. External drags are not supported.
`Gui.dialog` lowers the explicit `dialog` tag, semantic label, native style,
and an ordinary Escape shortcut. It needs no additional ABI field. Rust copies
the existing committed parent ID so modal membership follows engine topology.
Presentation relocates the dialog view into an occluding overlay without
changing its parent or mounting a second reactive scope. Simultaneous dialogs
must form one chain of at most eight nested elements.

Focus ownership uses weak retained-view identity, the engine lifetime stamp,
and weak GPUI focus handles.
Opening a modal focuses its first enabled button, checkbox, or input; an empty
modal focuses itself. Exact Tab/Shift-Tab wrap through current child order,
and exact Escape dispatches the current dialog's normal scoped message.
Enter/Space activate focused buttons; Space activates checkboxes using their
current checked state. Disabled controls retain focus identity and reject
activation. Background pointer, editor, control, and region callbacks cannot
enter the engine while another modal owns input. Disposing a dialog restores
its prior live enabled control, otherwise its parent dialog, otherwise clears
focus. A recycled render slot cannot substitute for its former focus owner.

Modal registration updates touch the changed batch and at most eight active
registrations. Opening, restoring, or explicit Tab navigation may traverse only
the relevant modal, bounded to 1,024 nodes and 256 enabled controls. Ancestry
checks are likewise bounded to 1,024 parent links. These limits
are programmer contracts checked by the GUI adapter after engine publication,
before a target list is used. Violations terminate the host; they are not
retriable capacity refusals and cannot continue with a partial modal or focus
state. There is no whole-application focus scan on a reactive update. Native semantic specs exercise
ordinary dialog scopes and Escape bindings, while GPUI adapter tests own focus,
keyboard precedence, pointer occlusion, nesting, and retained-identity checks.

Native editors accept at most one MiB of UTF-8 text, matching the ingress and
Files read limits. An oversized user insertion, paste, or IME replacement is
refused in full before changing text, selection, or composition; it emits no
engine event. Deleting or replacing a selection can make room for a later edit.
Oversized authoritative application values remain contract errors. Ordinary
value or availability updates retain the editor entity; a changed engine
lifetime, input binding, or editor kind creates a fresh editor callback. Old
callbacks must match both the captured lifetime and current event binding.

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
Diagnostic detail is at most **4096 UTF-8 bytes**, including an explicit
` [truncated]` suffix when detail was omitted. Error codes remain unchanged;
paths, text, and metadata results are never truncated.

`choose_save_path` takes `{directory: [Home, At(Str)], suggested_name: Str}`.
`Home` resolves the native environment's UTF-8 `HOME`; a missing or non-UTF-8 value
returns `Unavailable`. `At` supplies an explicit initial directory. Both paths
must be absolute and valid. In the private request record `home` requires an
empty directory frame; `at` carries the supplied path. No empty-path convention
is exposed to applications. Suggested names must be a single nonempty file name
of at most **255 UTF-8 bytes**; invalid names return `InvalidPath`.

Paths are absolute UTF-8, at most **4096 bytes**; invalid paths and unsupported
traversal return typed errors. Text reads and writes are bounded at **1 MiB**.
Scans return one complete metadata result of at most **10,000 entries**, **64
levels**, and **4 MiB of paths including the root**. They observe the filesystem
over time; concurrent changes may fail the scan. Symlinks and other entries are reported
without traversal. Limits refuse the entire operation instead of truncating it.
Writes create a temporary sibling, write and synchronize the immutable submitted
text, and rename it into place. This guarantees atomic replacement; the parent
directory is not synchronized, so power-loss durability is not guaranteed.
Failure or cancellation before commit attempts to remove the temporary file;
failed cleanup returns `Io` and may leave that file behind. Cancellation cannot
undo a rename that has already committed.


## Native timers

The separate timer boundary is version **1**. Before mount, Rust checks
`signals_timer_version()` and `signals_timer_size()`. `signals_timer_next(out)`
returns zero when empty or one with `{token: u64, period_ms: u64, action: u32,
reserved: u32}`. Action 1 starts the exact engine-issued token and period; action
2 cancels it and has period zero. The reserved field is zero.
`signals_timer_tick(token)` returns one after ordinary propagation or zero for a
callback invalidated by disposal. It never routes by matching periods.

At most **256** intervals may be committed or reserved by a native transaction.
Reservation failure rejects preparation before publication. A fixed **512-slot**
notification pool also holds cancellations of previously announced timers while
new registrations are published. Starts canceled before the adapter reads them
release immediately. Lookup, enqueue, cancellation, and notification draining
touch only the affected identities. A pending cancellation invalidates delivery
before the native task handle is dropped. Shutdown cancels native jobs before
engine teardown.

Native periods are executor wake intervals; each wake submits one tick, without
inventing elapsed-time values or merging queued ticks. Long waits are split into
day-sized executor waits to avoid overflowing native clock arithmetic. Normal
smoke checks disable clocks for deterministic assertions; `--smoke-timers`
enables real timer delivery and waits 1.2 seconds after the requested action.
