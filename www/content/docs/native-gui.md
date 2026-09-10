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
controls. The current targets are Apple Silicon macOS, Linux x86_64 with glibc and a Wayland/GPU session, and Windows x86_64;
see [contributing](@/docs/contributing.md#native-gui-platform-spike) for the pinned
compiler, host build, executable build, and test commands.

## Try a release candidate

Download and extract the starter archive for your operating system:

| Native target | Starter archive | Release |
| --- | --- | --- |
| Linux x86_64 (glibc/Wayland) | [signals-gui-starters.zip](https://github.com/lukewilliamboswell/roc-signals/releases/download/gui-0.1.0-rc.1/signals-gui-starters.zip) | [gui-0.1.0-rc.1](https://github.com/lukewilliamboswell/roc-signals/releases/tag/gui-0.1.0-rc.1) |
| Apple Silicon macOS | [signals-gui-starters.zip](https://github.com/lukewilliamboswell/roc-signals/releases/download/gui-0.1.0-rc.2/signals-gui-starters.zip) | [gui-0.1.0-rc.2](https://github.com/lukewilliamboswell/roc-signals/releases/tag/gui-0.1.0-rc.2) |
| Windows x86_64 | [signals-gui-starters.zip](https://github.com/lukewilliamboswell/roc-signals/releases/download/gui-0.1.0-rc.3/signals-gui-starters.zip) | [gui-0.1.0-rc.3](https://github.com/lukewilliamboswell/roc-signals/releases/tag/gui-0.1.0-rc.3) |

Install Roc `nightly-2026-09-04-c125b82`, the compiler named in each app's header.
From the extracted directory, build Counter for your target:

```sh
# Linux x86_64
roc build --target=x64glibc --output=counter examples-gui/counter/main.roc

# Apple Silicon macOS
roc build --target=arm64mac --output=counter examples-gui/counter/main.roc
```

Then run `./counter`. On Windows, use PowerShell:

```powershell
roc build --target=x64mingw --output=counter.exe examples-gui/counter/main.roc
.\counter.exe
```

Each download includes all six example apps and their
companion files. Roc fetches the pinned platform archive, which contains the
compiled host and its link inputs; building these apps requires no Rust, Zig,
or repository checkout. Preserve the bundled notices when redistributing the
platform.

Linux requires glibc, a Wayland desktop and a working graphics driver. The
operating system supplies runtime libraries, including FreeType and xkbcommon.
CI validated Ubuntu 24.04 using software Vulkan, built every downloaded app,
ran all 39 example specs, and checked rendering for all six apps.

The Mac download targets Apple Silicon, not Intel Macs. macOS supplies its
system frameworks and runtime libraries. Native CI rebuilt all six apps from
their unchanged published URLs with a fresh Roc cache, passed all 39 specs, and
confirmed rendering for every app.

The Windows download targets x86_64 and requires a native Windows desktop with
working graphics support. It bundles GNU runtime link inputs and complete DLL
import libraries; Windows supplies the system DLL implementations. Building the
starters does not require a Windows SDK or a C/C++ compiler. Native CI rebuilt
all six apps from their unchanged published URLs with a fresh Roc cache, passed
all 39 specs, and confirmed rendering for every app.

## Controls and layout

`Gui.row`, `Gui.column`, and `Gui.panel` take a props record followed by a
child list. Every control has its own props type, such as `Gui.PanelProps`,
whose fields all have defaults, so a literal names only what it changes:
`Gui.column({ test_id: "count", padding: 12, gap: 4 }, ["Count"])`. A string
literal in a child list is literal text, the same as `Gui.text`. The style
fields carry that control's own presentation defaults: a panel keeps its
padding and border unless the literal sets them. Attributes such as `test_id`,
`label`, `selected`, `enabled`, `disabled`, `shortcuts`, `drag_source`, and
`on_drop` live in the same record and cost nothing when omitted.

`changes` takes a `Signal(Gui.Style)` and replaces the static style fields
through normal signal propagation. A record built inside a `Signal.map`
transform is constructed explicitly as `Gui.Style.{ ... }` so its omitted
fields still take their defaults; the same applies to a props record built
outside the call, for example `Gui.PanelProps.{ padding: 4 }`, because only a
literal passed directly to the control absorbs its defaults.

Styles specify logical-pixel dimensions, spacing, padding, colors, borders,
radius, font size, and overflow. Lengths are `Auto`, `Fill`, or `Px(value)`;
colors are `Default` or `Rgb(value)`. Zero font size and default colors inherit.
`Fill` means the parent's content box: a Fill child stays inside the parent's
padding and shares the remaining space with its siblings, and its own content
never grows the allocation - give a Fill region `Scroll` or `Clip` overflow
when its content can exceed it. These are native presentation properties.
Semantic labels, test IDs, selected state, and enabled state are separate
attributes.

`hover_background` and `active_background` color an enabled button while the
pointer rests on or presses it. Default state colors keep the host's standard
feedback on default-background buttons and leave explicitly colored buttons
unchanged, so declare them alongside an explicit `background` - typically as
theme knobs next to the accent color. Text inputs and textareas render their
inner field from the same style record: explicit `background`, `foreground`,
`border_color`, `radius`, and `font_size` replace the host's dark field
defaults, the placeholder derives from the foreground at reduced alpha, and
an explicit foreground also tints the cursor and selection, so a
light-background editor is fully legible.
The initial window is 1200 × 820 logical pixels and can be moved, resized,
minimized, and maximized. The host requests client decorations on Wayland and
supplies a draggable title bar and resize borders when the compositor delegates
them to the app. The title-bar Close button uses the same `Gui.window_lifecycle` close
guard as an OS close request. The minimum window size is 360 × 240 logical pixels.
Apps own their content padding; the frame sits outside that content.

Window overflow, scrollable panels, virtual lists, and editors show draggable
scrollbars when content exceeds the viewport. Clicking a track positions its
thumb at the pointer; wheel and touchpad scrolling remain available. `Clip`
does not acquire scrolling controls. Scroll offsets belong to native views and
do not dispatch application events.

| Control | Inputs |
| --- | --- |
| `heading`, `text` | literal string; a child list also accepts a bare `"string"` as text |
| `text_s` | string signal |
| `button` | label and unit message |
| `action_button` | `{ caption, enabled, ... }` props with signal caption, unit message |
| `text_input`, `textarea` | `{ label, value, ... }` props, string message |
| `checkbox` | `{ label, checked, ... }` props, boolean message |

Text controls are controlled: their value comes from a signal and committed
edits enter the corresponding message handler. Native editors retain selection,
clipboard behavior, and IME preedit locally. `textarea` preserves hard line
breaks and wraps paragraphs to the available viewport width without changing
the document text. Caret movement, pointer selection, and composition bounds use
those visual rows. Text input is bounded at 1 MiB.
Control+Z undoes native edits; Control+Shift+Z or Control+Y redoes them.
Contiguous typing groups until whitespace, cursor movement, or a one-second
pause. Paste and composition form separate edit groups. Undo restores selection
and sends the restored text through the ordinary input handler. Each editor
retains at most 128 history boundaries and 8 MiB of text across undo and redo;
oldest boundaries expire first. A different authoritative document value clears
history, while equal input echoes preserve it. Disabled editors refuse undo and
redo.
An explicit textarea height (`Px` or `Fill`) includes its caption and padding and
constrains the retained editing viewport. `Auto` keeps a 320-pixel editor. Use
`Fill` inside a container with a defined height to grow and shrink with its space.
The `enabled` and `disabled` signal fields change availability while preserving
the control's identity.
The `placeholder` field shows an explicit empty-field hint inside `text_input`
and `textarea` while their document is empty, for example
`Gui.text_input({ label, value, placeholder: "Filter tasks…" }, msg)`.
The hint is static text declared by the app; a field without it shows an
empty field, and labels are never reused as hint text.
Tab and Shift-Tab traverse enabled controls in native layout order. Focused
control actions and declared shortcuts run first; modal dialogs own their Tab
navigation while open.

`Gui.image({ source, label, ... })` renders a picture from a relative path
inside the host's assets root, sized and rounded by its style, for example
`Gui.image({ source: "avatars/maya.png", label: "Maya avatar", width: Px(24), height: Px(24), radius: 24 })`.
Launch the host with `--assets-root <dir>` (or `ROC_SIGNALS_ASSETS_ROOT`) to
choose the root; the default is `assets/` beside the executable. Absolute
paths, `..` traversal, URIs, and symbolic links never resolve, and a missing or
undecodable image shows a neutral placeholder box instead of nothing.
Ship an `assets/manifest.json` next to `main.roc`, ingest it at compile time,
and start `Files.verify_assets` at mount to report each asset as ok, missing,
or altered; the task-board and folder-explorer examples show the pattern.

Use the `test_id` field for stable spec locators and `label` for semantic
names; on an `action_button`, `label` replaces the live `caption` as the name.
Labels do not establish native screen-reader support, which is not implemented.

## Embedded fonts

Apps can ship fonts inside the binary and register them with the native text
system at startup. Embed the bytes with a compile-time import and declare them
once on the app's root element:

```roc
import "../../vendor/fonts/source-code-pro/SourceCodePro-Regular.ttf" as source_code_pro : List(U8)

Gui.column(
    { embedded_fonts: [{ family: "Source Code Pro", bytes: source_code_pro }], ... },
    [...],
)
```

`font_family: "Source Code Pro"` then renders an element and its descendants
with that family; text styles inherit, so one field on a row or panel covers
all of its text. Families not registered here must be
installed on the machine.

The host enforces bounds: at most 8 embedded fonts, at most 8 MiB per font,
and family names of 1 to 128 bytes. Violations surface as visible host errors
rather than crashes, and identical re-publication never re-registers a family.
Only ship fonts whose licenses permit embedding and redistribution, and keep
the license text in the repository next to the font file.

## Modal dialogs

Use `Gui.dialog({ label, on_dismiss, ... }, children)` inside `Ui.when` so
mounting and disposal explicitly own the modal lifetime. `label` supplies the
semantic dialog name; `on_dismiss` is a normal unit message bound to Escape.
Closing the dialog is the application's state transition, never hidden host
state. Native file choosers are separate `Files` tasks.

The host focuses the first enabled button, checkbox, or text control when a
dialog opens. Tab and Shift-Tab wrap through its current child order. Buttons
activate with Enter or Space and checkboxes with Space; native editing actions
keep precedence over region shortcuts. Disabled controls remain mounted but
cannot activate. The innermost dialog blocks pointer and keyboard events from
the background, and disposal restores the prior control when it is still live
and enabled. An empty dialog retains focus itself; if a saved focus owner was
disposed or disabled, the parent dialog receives focus, or focus clears when no
modal remains.

Concurrent dialogs must form one nested chain, limited to eight dialogs. Each
modal admits at most 1,024 nodes and 256 enabled focus targets. Exceeding these
programmer limits, or 1,024 parent links during an ancestry check, terminates
the native host. The host checks
current child order when opening or navigating the modal, without scanning the
application during reactive updates. Native semantic specs can locate
`(role dialog :name "Discard your changes?")`; GPUI tests verify actual focus
and pointer behavior. This capability is native only and does not add browser
modal behavior or a window-close guard.

## Wide lists

`Gui.virtual_list({ row_height, follow_tail, ... }, children)` lays out only
the visible child range. Give every direct child the same fixed logical height;
`row_height` must be between 1 and 16,384. Use `Ui.each` for keyed child rows.
`follow_tail` is a boolean signal that keeps the final row visible as history
changes when enabled.

Virtualization bounds native child lookup and layout work. Reactive row scopes
remain mounted, so the application still owns its data retention policy. The
Activity Monitor example caps replay and file history at 1,000 entries and 4 MiB of text. Ordinary
containers enumerate their direct children when rendered; choose the virtual
list for a wide collection.

## Keyboard regions

The `shortcuts` field, a list of `{ chord, msg }` records, binds unit messages
within a focused region.
A chord is `{ key, control, shift, alt, meta }`, with every modifier explicit.
Use lowercase letters, digits, or named keys: `Enter`, `Escape`, `Tab`, `Space`,
`ArrowLeft`, `ArrowRight`, `ArrowUp`, `ArrowDown`, `Home`, `End`, `PageUp`,
`PageDown`, `Backspace`, `Delete`, and `F1` through `F12`. Matching is exact. The nearest matching ancestor
receives the event; native text-editing actions take precedence.

A region accepts at most 32 shortcuts. Duplicate chords are errors. Registrations
belong to their element's scope and stop receiving events after disposal.
See `test/gui/shortcuts` for a complete app and scoped routing spec.

## Internal drag and drop

Set `drag_source: key` on a card and `on_drop: message` on a destination. Keys are nonempty strings of at most 256 UTF-8 bytes. Create the
message with `Ui.action_detail` or `Ui.State.on_detail` to receive that key and
return the same commands used by keyboard or button alternatives. The key is
payload data; keyed row identity remains explicit in `Ui.each`.

Drops from disposed, replaced, disabled, or rebound controls are refused. This
API supports drags inside one running application. It does not accept files or
other external desktop drag payloads.

## Scoped timers and files

`Signal.interval(period_ms)` registers a native timer while its declaring scope
is live. Every tick enters the shared engine; scope disposal cancels the native
job and rejects any stale callback. Native transactions reserve at most 256 live
or newly declared timers. Activity Monitor uses a 500 ms interval whose scope is
present only while replay is running or a followed log is waiting for more data.

`pf.Files` provides native file/directory choosers, UTF-8 reads, atomic text
writes, recursive scans, direct-child directory listings, bounded previews,
incremental log reads, and associated-application launches as typed tasks. Use `Signal.from_task` to
observe results and `Signal.cancel` to invalidate pending work. See the
[task reference](@/docs/reference.md#native-files) for signatures, errors, and
bounds. A dismissed chooser returns `Choice.Canceled`; explicit task cancellation
returns `Error.Canceled`. Keep the submitted write snapshot separate from the
editable draft so a completed save cannot incorrectly mark later edits as saved.

## Example coverage

The collection in `examples-gui/` exercises platform features through ordinary
application workflows. `counter` is the minimal starting point; `keyed-rows`
shows retained row drafts and scoped structure.

| App | Main workflow |
| --- | --- |
| `task-board` | Open/save board documents, create/edit/drag keyed tasks, undo changes, and protect unsaved work on close |
| `notes-editor` | Edit wrapped multiline documents with undo, open/save real files, and wait for saves before closing |
| `folder-explorer` | Navigate real folders with breadcrumbs/history, filter/sort, preview text, and open files in their associated application |
| `activity-monitor` | Follow a real UTF-8 log or run explicit replay; pause, retry, filter bounded history, and inspect complete records |

Activity Monitor explicitly separates simulated replay from chosen plain-text
log files. Folder Explorer labels its sample workspace and offers an explicit
chooser for real directory navigation.

Notes uses the pinned Roc Unicode package for Unicode 17 grapheme counts and
word segmentation. Its word count includes segments containing letters or
numbers, excluding punctuation and emoji-only segments. Statistics preserve the
original text and do not imply language-specific dictionary segmentation.

Every registered app has native semantic specs. The GUI suite also runs GPUI
adapter tests with simulated input and layout. A native window smoke run checks the
linked renderer and adapter; an actual pointer, keyboard, and IME walkthrough
remains a separate form of validation.

## Window close decisions

Wrap the app's top-level content in `Gui.window_lifecycle` to protect work before
closing. Its `on_close_requested` message receives a unit event through the
ordinary graph. Its `decision` is a `Signal(Gui.CloseDecision)`:
`KeepOpen` cancels the request, `AwaitDecision` waits for confirmation or work,
and `Close` completes the pending request. This lets a save result close the
window only after the write succeeds. Close without a pending request is inert.

Declare exactly one wrapper directly beneath the app root. Repeated native close
requests while awaiting a decision are ignored. Disposing or replacing the
wrapper cancels its pending request; the native adapter validates registration
lifetime and binding. Apps without a wrapper close immediately. The Notes
example demonstrates Save and close, Discard and close, and Keep editing.
