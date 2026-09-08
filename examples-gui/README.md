# Native example collection

These applications exercise the shared Signals engine through the native GPUI
adapter. They use explicit Roc state and commands, keyed structure, and scoped
effects. The collection aims for complete application workflows with a small
public API; it is not a catalog of every GPUI capability.

| Application | Workflow | Platform coverage |
| --- | --- | --- |
| [Task Board](task-board/) | Organize, edit, filter, reorder, and transfer tasks | Keyed rows, selection, cross-list commands, drag/drop, confirmation |
| [Notes Editor](notes-editor/) | Edit documents, open files, save snapshots, confirm unsaved changes | Multiline input, clipboard, shortcuts, modal focus, native file tasks |
| [Folder Explorer](folder-explorer/) | Browse sample metadata or scan a chosen directory, sort, filter, inspect | Choosers, cancellable background work, typed failures, virtual lists |
| [Activity Monitor](activity-monitor/) | Start, pause, filter, and inspect a deterministic event replay | Scoped timers, bounded history, virtual lists, follow-tail |

Activity Monitor shows simulated operations, not measurements of the host.
Folder Explorer starts with sample metadata and explicitly offers a real directory
scan. Notes Editor reads and writes real files through native tasks. See each
app's source and specs for the state transitions and error handling.

[Counter](counter/) and [Keyed Rows](keyed-rows/) remain small starting points.
The [native GUI guide](../www/content/docs/native-gui.md) describes public controls;
[contributing](../www/content/docs/contributing.md#native-gui-platform-spike)
covers the pinned compiler, host build, executable commands, and validation.
The supported native target is Linux x86_64 with glibc and Wayland.

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
Wayland run for rendering integration. A smoke command that injects an adapter
event does not establish operating-system pointer, keyboard, or IME behavior.

When working in parallel, isolate app slices in worktrees and assign shared API
files to one owner. Integrate focused commits as their checks pass, then rerun
the combined workflows. Shared changes also require the relevant browser,
ownership, allocation-refusal, and lifecycle regressions. An example should
expose a platform gap, not hide it behind duplicated application semantics.
