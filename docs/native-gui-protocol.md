# Native GUI presentation boundary

The tabular protocol contract - the protocol/effect/timer versions, the scalar
text and boolean field tables, the task-kind routes, and the extern node record
layout - has one authority: `protocol/native-protocol.json`. Running
`python3 scripts/generate_protocol.py` regenerates the committed artifacts
(`src/signals/native_protocol_gen.zig`, `crates/gpui-host/src/protocol_gen.rs`,
the marked section of `platform-gui/Elem.roc`, and the tables below);
`scripts/test.py zig` fails when any of them is stale. The prose in this
document stays hand-written.

<!-- BEGIN GENERATED PROTOCOL TABLES (scripts/generate_protocol.py; edit protocol/native-protocol.json) -->

The statically linked GUI boundary uses protocol version **12**
and the separate timer boundary is version **1**.

| Version | Change |
| --- | --- |
| 12 | Adds the `native_read_only` boolean field and its node word: a control that refuses edits while staying readable and keyboard reachable, distinct from disabled. |
| 11 | Adds `signals_document_title`, the host read of the window identity decided by the shared engine's `SetDocumentTitle` command. |
| 10 | Extends the presentation record to style version 2 with hover and active background slots (18 u32 style record); style version 1 records are no longer accepted. |
| 9 | Adds the explicit image-source text slot together with the font-family and embedded-font declaration slots to the node layout. |
| 8 | Adds the placeholder text slot to the node layout. |
| 7 | Adds explicit event-detail dispatch to `signals_dispatch`. |
| 6 | Adds the close-request event ID and close-decision word to the node layout. |

Scalar text fields:

| Id | Field | Scope | Purpose |
| --- | --- | --- | --- |
| 1 | `text` | browser (`set_text`) | Element text content. |
| 2 | `role` | browser (`set_role`) | Semantic role string. |
| 3 | `label` | browser (`set_label`) | Visible caption and semantic name. |
| 4 | `test_id` | browser (`set_test_id`) | Stable test selector identity. |
| 5 | `value` | browser (`set_value`) | Controlled input value. |
| 6 | `class` | browser (`set_class`) | CSS class list for browser presentation. |
| 8 | `native_style` | native | Versioned native presentation record; never encoded on the browser wire. |
| 9 | `native_viewport` | native | Fixed-row virtual list record `1,row_height,follow_tail`. |
| 10 | `native_drag_key` | native | Bounded application key exposed by an internal drag source. |
| 11 | `native_window_close` | native | Window close policy: `keep-open`, `await-decision`, or `close`. |
| 12 | `native_placeholder` | native | Static empty-field hint text shown while a controlled field is empty. |
| 13 | `native_image_source` | native | Relative image source resolved against the process-wide assets root. |
| 14 | `native_font_family` | native | Static font family joined into the element's inherited text style. |
| 15 | `native_fonts` | native | Versioned embedded-font registration declaration; registered once at startup. |
| 7 | - | shared | Reserved marker for named custom text attributes. |

Scalar boolean fields:

| Id | Field | Scope | Purpose |
| --- | --- | --- | --- |
| 1 | `checked` | browser (`set_checked`) | Checkbox checked state. |
| 2 | `disabled` | browser (`set_disabled`) | Disables input while retaining native identity. |
| 4 | `selected` | native | Native selected presentation, independent of checkbox state. |
| 5 | `native_drop_target` | native | Marks an internal drop target that must bind a string-detail drop event. |
| 6 | `native_read_only` | native | Refuses user edits and edit history while the control stays available at full contrast and in tab order. |
| 3 | - | shared | Reserved marker for named custom boolean attributes. |

`Node.TaskKind` is an explicit closed route:

| Id | Kind | Purpose |
| --- | --- | --- |
| 0 | `external` | App-declared external task; the only route the browser host accepts. |
| 1 | `choose_file` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 2 | `choose_directory` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 3 | `choose_save_path` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 4 | `read_text` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 5 | `write_text` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 6 | `scan_directory` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 7 | `list_directory` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 8 | `open_path` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 9 | `read_preview` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 10 | `read_log` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |
| 11 | `verify_assets` | Reserved; the native platform serves this through a hosted `Files` function, not a task route. |

<!-- END GENERATED PROTOCOL TABLES -->

Zig exports `signals_protocol_version` and `signals_node_size`; Rust checks
both before mount. Both sides must be rebuilt together.
The browser protocol and its version are unchanged.

`Gui` lowers native presentation through the shared scalar descriptor
machinery using the text and boolean field ids tabled above. The reserved
IDs 7 and 3 remain the existing custom text/bool field markers. Native fields
are explicit protocol fields, not CSS, class names, test identifiers, or custom
attribute conventions. The browser rejects them before reserving or staging a
command batch. Native specs retain them through the ordinary render publication.
The native context also prepares a browser-shaped journal for shared structural
bookkeeping; these native fields publish only through its typed native
publication and never acquire invented browser opcodes.

The style field contains a canonical ASCII decimal record separated by commas:

```
version,direction,gap,padding,width_kind,width,height_kind,height,grow,background,hover_background,active_background,foreground,border_color,border_width,radius,font_size,overflow_x,overflow_y
```

Version 2 has exactly these 19 fields. Numbers have no signs, whitespace, or
leading zeroes. Direction is row=0 or column=1. Length kind is auto=0, fill=1,
pixels=2; auto/fill must have a zero value. Grow is 0 or 1. Overflow is
visible=0, clip=1, scroll=2. Colors are 24-bit RGB or 16777216 for inherited/default.
Lengths, spacing, radius, borders, and font size are logical pixels, bounded at
16384. Font size zero inherits. Invalid records are programmer-contract errors,
not a request to substitute defaults. Records are bounded at 224 bytes.
Retired version-1 records (17 fields, without the state backgrounds) are
refused like any other invalid record: platform and host are statically linked
and ship together, so no compatibility window exists.

`hover_bg` and `active_bg` color enabled buttons while the
pointer rests on or presses them. An explicit state color always wins; with
both at the inherit sentinel, a default-background button keeps the host's
standard hover/active feedback, and an explicitly colored button shows no state
change. Checkboxes and non-interactive elements ignore the state slots: a
checkbox's feedback is its glyph and cursor, and a row-wide highlight would
misstate its hit area.

The public `Gui.Style` contains typed lengths, colors and overflow tags. Only the
platform encoder creates records. `Elem.row`/`column`/`panel` choose direction;
each control's props record carries the remaining fields with that control's
defaults, and a `changes` signal replaces them. Each element publishes one
style.
The style signal is an ordinary typed, equality-pruned signal; there is no
native styling observer graph.

Zig validates the style during native publication preparation and exports an
`extern` struct of 18 `u32` fields in the order after `version` above. Rust copies
this validated record along with primitive fields and borrowed UTF-8 data before
any next engine operation. Rust applies the supplied layout and presentation
properties with GPUI. Selected state adds the standard selection border, and
disabled state applies reduced opacity and refuses input dispatch.
The semantic root fills the host viewport, and apps own outer padding.

Fill means the parent's content box. On the parent's main axis the host maps
Fill to flex distribution of the free space (zero preferred size, grow, zero
minimum), so a Fill element stays inside the parent's padding, shares the
remaining space with its siblings, and never grows with its own content; a
Fill region that can overflow declares its own `Clip` or `Scroll`. On the
cross axis Fill is a percentage of the parent's content box. The committed
parent's direction decides which axis is which.

Text inputs and textareas resolve their inner field from the same record:
explicit `bg`, `fg`, and `border_color` replace the host's
dark field defaults, a nonzero `radius` replaces the standard rounding, and a
nonzero `font_size` sizes the editor text with a proportional line height.
The placeholder derives from the effective foreground at reduced alpha, and
an explicit foreground also tints the cursor and the selection highlight.
Explicit textarea heights constrain the complete field; the retained editor
fills the space after caption and padding. Auto presentation retains a
320-pixel editor.

The `read_only` props field lowers boolean field 6. Read-only is not disabled, and the
two are separate fields because they make different claims. Disabled says a
control is unavailable: the host dims it and removes its tab stop. Read-only
says the document belongs to the application: the control keeps its ordinary
contrast and its place in the tab order, still takes focus, selects, copies
and scrolls, and still accepts an authoritative value — but every user edit
route and the native undo and redo history are refused. Nothing a person does
can move the shown text away from the published value, so a read-only editor
cannot diverge from its source the way an enabled one with ignored change
events would. A control may carry both fields; disabled's presentation and
tab-stop effects apply on top, and either flag alone refuses edits.

The `placeholder` props field lowers static empty-field hint text through field 12. The
hint is app-declared configuration, not host behavior: the host shows exactly
the supplied text while a controlled field's document is empty, and a field
without it shows nothing. Labels never become placeholder text, and
the host holds no default hint strings. The browser host rejects the field like
every other native scalar.

`Elem.image` lowers element tag `img` with its relative source text on field
13. The source is application data, not a filesystem capability: the host
resolves it against one process-wide assets root (`--host-assets-root <dir>`, else
`ROC_SIGNALS_ASSETS_ROOT`, else `assets/` beside the executable) and refuses
absolute paths, `..` traversal, URI schemes, backslashes, and symbolic links
anywhere below the root. Sources are 1 to 1024 UTF-8 bytes. A source that does
not resolve to a regular decodable image renders a neutral placeholder box
(surface `0x1B2A33`, border `0x3A4F5C`) of the element's styled size; nothing
is fetched remotely. The display-free spec host stores the field like every
other native scalar and never touches the filesystem.

The `font_family` props field lowers a static family name through field 14. The GPUI host
joins the family into the element's inherited text style, so descendants
without their own family render with it. The family must be installed on the
machine or registered through the embedded-font declaration below; an unknown
family falls back through GPUI's ordinary font resolution.

The `embedded_fonts` props field lowers a startup font registration through field 15. The
value is a newline-delimited v1 record: a `1` version line, then one family
line and one standard-base64 data line per font. Families are 1 to 128 UTF-8
bytes without control characters. The record is bounded at **8 fonts** and
**8 MiB of decoded bytes per font**; the Zig engine validates structure and
bounds before publication, and the GPUI host re-validates, decodes, and calls
`add_fonts` exactly once per family at startup. Bound violations are visible
host errors, never panics, and never partial registrations. Re-publishing an
identical declaration is pruned by content identity; the same family with
different bytes is refused, because a text system cannot unregister fonts.
Base64 costs one third extra over the raw bytes while the declaration string
is alive; the app binary embeds only the raw compile-time import, and the
encoding happens once while the element tree is built. The display-free spec
host stores the validated declaration without touching any text system.

Ordinary Tab and Shift-Tab use GPUI's committed tab-stop index after focused
handlers decline the key. A Runtime owns one window-filtered GPUI subscription
for Tab when no control is focused, because that dispatch path does not enter
the rendered div. The subscription is released with the Runtime and never
handles other modified Tab chords or an active modal dialog.

`signals_dispatch` accepts event ID, payload kind, UTF-8 pointer/length, and a
boolean word. Kind 0 is unit, kind 1 is controlled input value, kind 2 is checked boolean,
and kind 3 is event-detail text (including native drop keys); boolean
payloads require zero text bytes and a value of 0 or 1. Unit payloads require
zero text bytes and a zero boolean word; text payloads require valid UTF-8 and
a zero boolean word. Each kind uses the shared
engine's existing event extraction descriptor and capability-owned reducer path.
Input value and event detail remain distinct even though both carry UTF-8 text.
Version 7 adds the explicit detail kind; rebuild the host and app together.
Deferred callbacks validate both node identity and current binding, and cannot
update disposed or rebound controls.

`Elem.window_lifecycle` declares one `window` element directly beneath the
semantic root. Field 11 carries exactly `keep-open`, `await-decision`, or `close`,
and a native unit `close-requested` binding is mandatory. Preparation rejects
nested or duplicate registrations, missing bindings, invalid policy text, and
wrong payload schemas before publication. The raw close-decision word is zero
for an unregistered node, otherwise KeepOpen=1, AwaitDecision=2, Close=3.

A native close request dispatches that current event through ordinary engine
propagation. KeepOpen cancels the request, AwaitDecision retains one pending
request, and Close grants closure only for that pending registration. Repeated
OS requests while awaiting a decision do not dispatch another event. An async
save can publish Close later; rendering then removes the window. Committed
permission belongs to the window until the frame: later policy changes or
registration retirement cannot revoke the decided effect. Close with no
pending request is inert. Pending ownership includes element, view, lifetime,
and event binding; disposal, replacement, or rebinding cancels an undecided
request. Once Close commits, closure is terminal. Teardown
releases the registration with its runtime. An app without a registration uses
the normal immediate-close behavior. No native code knows whether an app is dirty.

Native specs provide `request-window-close` and `expect-window-closed` as a
semantic simulation of this protocol; GPUI tests exercise the installed native
close callback separately.

Each `shortcuts` entry adds a typed `key_chord` filter to the canonical shared event
binding. It always uses a unit `keydown` route with native delivery and static
prevent-default/stop-propagation policy. Filter identity is the complete key and
modifier record; event identity still comes from construction within the owning
scope. Duplicate chords are errors, and each element accepts at most 32. The
browser rejects these filters during descriptor collection and again before wire
staging. The native publication retains them without inventing browser opcodes.

The public `Event.KeyChord` record has `key: Str` and four boolean fields:
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
the `drag_source` props field. `on_drop` binds an ordinary native `drop` event with a
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
`Elem.dialog` lowers the explicit `dialog` tag, semantic label, native style,
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
establish native screen-reader support: this adapter does not publish an
operating-system accessibility tree.

`Elem.virtual_list({row_height, follow_tail}, attrs, children)` presents direct
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

`signals_document_title(out)` reports the window identity the graph decided and
returns a revision that changes only when the applied title text changes. The
slice borrows engine-owned storage that stays valid until the next engine call,
so the host copies it before dispatching again. It is an observation of the
shared engine's `SetDocumentTitle` command, exposed by `Gui.set_title`, and not
a second route into the window: the host applies a title on the next frame and
skips a revision it has already applied.

## Effect preparation ownership

The engine calls `roc_prepare_effect` on the UI thread to turn an effect
closure and its reads snapshot into an independently owned worker thunk.
The export consumes the supplied effect callable and capability references;
the numeric snapshot handle is borrowed, and Roc reads its value through that
capability. The engine retains separate references for the export so its own
capability remains valid when it drops the snapshot after preparation. The
returned thunk owns the Roc values needed by the worker. `roc_run_effect`
consumes that thunk and returns an owned command for the engine to apply.

## Native Files

`Files` exposes the host's file primitives as hosted effectful functions:
three choosers, `stat`, `read_bytes`, `write_bytes`, `rename`, `remove`,
`sync`, `list_directory`, `open_path`, and `assets_root`. Each call runs to
completion on the effect worker that made it and returns a typed result;
nothing is queued, tracked, or canceled by the engine. Everything the platform
offers above those primitives, text reads and atomic text writes, previews,
recursive scans, and asset verification, is Roc code in the `Files` module,
and the activity monitor's log reader is Roc code in that app. The route
numbers in `Node.TaskKind` remain only for the engine's own tasks; the native
platform routes nothing through them.

Each primitive is its own hosted entry point with the argument and result
types the glue generates from its Roc signature: `roc_files_read_bytes` takes
`{ path, offset, max_bytes }` and returns `Try({ bytes, size }, Error)` as an
extern tag union, and so on. The Zig host releases the owned arguments and
builds the result value directly. In a live window the work happens in Rust,
which returns plain C structs, buffers with a pointer and length, that the
host copies into Roc values and releases through the matching
`signals_*_release`. The spec host answers the same calls from declared
`stub-file-*` results instead and never touches the filesystem. No Roc value,
callable, layout, or pointer leaves the worker that made the call, and nothing
crosses either boundary encoded as text.

Choosers need the windowing event loop. The worker posts the request to the UI
thread's mailbox and blocks on a reply channel; the UI thread shows the desktop
portal dialog and replies when it settles. Other effects keep running on their
own workers meanwhile. The pinned GPUI API provides no handle for closing an
already open dialog, so a chooser settles only when the user does. Closing the
window while a chooser is open answers the waiting worker with `Unavailable`.

Every path component is opened relative to an owned directory handle without
following symbolic links or reparse points, so a substituted link cannot
redirect an operation. `stat` reports the entry itself, never a link target;
`read_bytes`, `write_bytes`, and `sync` refuse anything but a regular file;
`rename` replaces only a regular file at its destination; `remove` unlinks a
file, a link itself, or an empty directory. Entry kinds are `File`,
`Directory`, `SymbolicLink`, and `Other`. `list_directory` returns direct
children sorted by path within the same 10,000-entry and four-MiB
aggregate-path bounds as a recursive scan, refusing the whole result on
overflow. `open_path` validates one regular file, passes its absolute pathname
to `gio open` without a shell, discards launcher output, and reports
`Unavailable` on launch failure or a 30-second deadline; the associated
application then resolves the path under its own access policy. A user
dismissing a dialog is `Ok(Choice.Canceled)`, not an error. Errors are `NotFound`, `PermissionDenied`, `InvalidUtf8`,
`InvalidPath`, `ResourceLimit`, `Io`, and `Unavailable`, each with diagnostic
detail of at most **4096 UTF-8 bytes**, including an explicit ` [truncated]`
suffix when detail was omitted.

`choose_save_path` takes `{directory: [Home, At(Str)], suggested_name: Str}`.
`Home` resolves the native user's profile root: `HOME` on Linux and macOS, and
`USERPROFILE` (falling back to `HOMEDRIVE` plus `HOMEPATH`) on Windows, where an
ordinary process has no `HOME`. Only an environment that names no UTF-8 directory
at all returns `Unavailable`. `At` supplies an explicit initial directory. Both paths
must be absolute and valid. Suggested names must be a single nonempty file name
of at most **255 UTF-8 bytes**; invalid names return `InvalidPath`. Paths are
absolute UTF-8, at most **4096 bytes**; invalid paths and unsupported traversal
return typed errors.

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
smoke checks disable clocks for deterministic assertions; `--host-smoke-timers`
enables real timer delivery and waits 1.2 seconds after the requested action.

## Adding a protocol field

The manifest owns the tables; the generator owns the transcription; a bounded
amount of behavior stays hand-written. To add a native scalar field:

1. Declare the field in `protocol/native-protocol.json`: append it to
   `text_fields` (or `bool_fields`) with a fresh id, `"native": true`, a
   `roc_const` name when `Gui` lowers it, and a one-line doc. Bump
   `protocol_version` and prepend a `version_history` entry. If the GPUI host
   reads the value directly, add its slot to `raw_node.fields` in the intended
   ABI position.
2. Run `python3 scripts/generate_protocol.py`. This regenerates the Zig/Rust
   enums, counts, and `RawNode` layouts, the `Elem.roc` constants, and the
   tables above. Every derived contract (metadata counts, descriptor-index
   sizes, `signals_node_size`, version asserts) follows automatically.
3. Write the honest residue - the behavior no table can express. The Zig
   compiler reports each site as a compile error (`inline else` field access
   and exhaustive switches), so the checklist is enforced, not remembered:
   - `src/sim_dom.zig`: an `Element` slot named exactly like the field.
   - `src/signals/render_cache.zig`: a matching `ScalarNode` slot.
   - `src/native_host.zig`: any publication-time validation, plus the
     `Gpui.read` expression that fills the new `RawNode` slot.
   - `crates/gpui-host/src/bridge.rs`: copy the new `RawNode` slot into `Node`
     (a missed slot is unused-field/`E0063`-adjacent, and the size assert plus
     `cargo test` catch drift) and present it in the host.
   - `platform-gui/Elem.roc`: a props field lowering to the generated
     `*_field` constant.
4. Describe the field's semantics in prose in this document, and rebuild both
   sides together (`python3 scripts/build_gui.py`).
