# Native example collection

These applications exercise the shared Signals engine through the native GPUI
adapter. They use explicit Roc state and commands, keyed structure, and scoped
effects. The collection aims for complete application workflows with a small
public API; it is not a catalog of every GPUI capability.

| Application | Workflow | Platform coverage |
| --- | --- | --- |
| [Task Board](task-board/) | Open and save board documents, undo edits and moves, protect unsaved work | Keyed rows, atomic commands, drag/drop, history, files, close decisions |
| [Notes Editor](notes-editor/) | Edit and undo wrapped text, save snapshots, protect drafts on close | Multiline input, clipboard, shortcuts, document lifetimes, native file effects |
| [Folder Explorer](folder-explorer/) | Navigate folders with history and breadcrumbs, preview text, open files | Directory effects, chooser cancel/retry, shortcuts, bounded previews, virtual lists |
| [Activity Monitor](activity-monitor/) | Follow a real log or run explicit replay, pause, retry, filter, and inspect | Incremental file effects, scoped timers, bounded history, virtual lists |

Activity Monitor separates simulated replay from explicitly chosen real log files.
Folder Explorer starts with a sample tree and offers real directory navigation,
text previews, and opening files in their associated application. Notes Editor reads and writes real files through native file effects. See each
app's source and specs for the state transitions and error handling.

[Counter](counter/) and [Keyed Rows](keyed-rows/) remain small starting points.
Counter and Notes Editor read their palettes from a `theme.json` parsed during
compile-time evaluation, so a malformed theme fails `roc build` with a message
naming the file and key.
The [native GUI guide](../www/content/docs/native-gui.md) describes public controls;
[contributing](../www/content/docs/contributing.md#native-gui-platform-spike)
covers the pinned compiler, host build, executable commands, and validation.
The supported native targets are Apple Silicon macOS, Linux x86_64 with glibc and Wayland, and Windows x86_64.

## Adding another example

Start with a concrete user workflow and a deterministic semantic spec. Sketch
its clearest Roc API, identify the missing capability, and implement that
capability at the shared engine or typed host boundary that owns it. Keep host
presentation separate from reactive scheduling and scope lifetime. Avoid adding
an app-specific host route when an ordinary signal, event, or command expresses
the behavior.

Complete one coherent slice across the platform, affected hosts, documentation,
and example. Register the app in `examples.toml`; the GUI suite discovers its
specs and the focused fixtures under `test/gui/`. Use native specs for visible
state and structural work, GPUI tests for layout and input dispatch, and a live
native window run for rendering integration. A smoke command that injects an adapter
event does not establish operating-system pointer, keyboard, or IME behavior.

When working in parallel, isolate app slices in worktrees and assign shared API
files to one owner. Integrate focused commits as their checks pass, then rerun
the combined workflows. Shared changes also require the relevant browser,
ownership, allocation-refusal, and lifecycle regressions. An example should
expose a platform gap, not hide it behind duplicated application semantics.
