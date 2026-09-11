# Launch Board

A small team task board with three columns, live detail editing, search, task
creation and confirmed deletion, drag movement, and explicit move controls. The seeded project is ready
to explore without an account or a service. Use Save to choose a `.board.json`
document, Save As to make another copy, and Open to reopen a saved project.

Start by editing a task's notes, filter its card out, and clear the filter. The
detail editor stays open because it belongs to the board, outside card scopes.
Drag onto another card to insert before it, or onto a column to move to its end.
The detail panel also offers controls to move to the top, bottom, or another
column. Its edited data follows it. Add two tasks with the same title to see that editable content is
independent of task identity.

Each column owns an independent `Rows` source. With no search active, its view
forwards the exact generation, allowing a single task edit or explicit move to
use sparse collection operations. An active search examines that column's
records explicitly. Selected-card styling uses `Signal.select`; changing the
selected task does not evaluate every card.

The detail panel retains its current task value in an ancestor scope. Field
actions write that value and the owning column atomically. Cross-column moves
write both columns and the editor together when the moved task is selected.

The editor also carries an explicit lifetime that names which task its native
inputs belong to. It is an allocated number, never inferred from the task's text
or from a key hidden in a label, and it changes exactly when the thing being
edited changes: selecting another task, creating one, undo, redo, and opening a
document all retire the current inputs, while editing, reordering, moving, and
filtering keep them. That is what stops one task's native selection and undo
history from reappearing in another whose fields happen to be equal.
Pointer drops and the explicit controls use the same domain reducer. The old card scope is disposed and
a new card scope is created at the destination; the application does not claim
that independent keyed-list sites transfer scopes.

Build and run with the [GUI contributor workflow](../../www/content/docs/contributing.md#native-gui-platform-spike).
Native semantic journeys live in `specs/`; they check editing, filtering,
repeated creation, dialog dismissal and deletion, selection, drops, movement, and structural
work. These specs model interaction semantics and do not establish actual
keyboard, focus, composition, or accessibility behavior in a native desktop session.

Collaboration, notifications, and remote synchronization are outside
this example. Deletion uses a scoped native dialog with Cancel and Escape.
Semantic drop tests exercise the shared action path; the native capability
fixtures separately cover pointer gesture delivery and stale drag rejection.

## Assets

Assignee avatars are tiny generated PNGs in `assets/` — regenerate them and
`assets/manifest.json` (real SHA-256 hashes) with `python3 assets/generate.py`
(`python` on Windows, where `python3` is usually the Store shortcut).
The app ingests the manifest at compile time and verifies it at startup through
`Files.verify_assets!`; if an asset is missing or altered, a danger-colored
status line names it while everything else keeps working.

That report is advisory and does not gate rendering. Drawing an avatar is the
host's own resolution and decoding of the file: an avatar the host cannot
resolve or decode — missing, unreadable, or not a valid image — shows a neutral
placeholder box, while a file that was altered but is still a valid image
renders its new contents. So "altered" in the status line does not imply a
placeholder, and a placeholder does not require a failed verification. The
check runs once at mount; restoring a file afterwards is reported by the next
run, not by the live status line. `specs/assets-problem/` holds a prepared
assets root exercising all three cases at once. When running the built binary directly,
point the host at the app's assets with
`--host-assets-root examples-gui/task-board/assets` (or `ROC_SIGNALS_ASSETS_ROOT`);
image sources are always relative paths inside that root.

## Documents and undo

The document stores version 1 JSON, explicit task identities, ordered columns,
and the next generated identity. Loading rejects malformed JSON, unsupported
versions, duplicate keys across columns, invalid next identities, oversized fields,
and boards over 500 tasks. Validation completes before replacing live data.
The encoded file must fit the native Files one-MiB limit. Task titles support
512 UTF-8 bytes, notes 8192, assignees 128, and keys 256. These are document byte
bounds, not character counts. Editing retains a draft beyond those limits so
validation does not discard text or disagree with the native input. Save explains
invalid fields or an oversized document without writing anything; shorten the
draft and retry. Native individual text controls also have a one-MiB input bound.

Open asks before replacing an unsaved board. Cancel or a failed read leaves the
board and its previous path intact, even after choosing to discard. A document
that loads successfully selects nothing, so no editor survives the replacement:
its tasks may reuse the previous document's keys, and picking one opens fresh
inputs on the new document. Saving holds
an immutable snapshot from the moment Save was requested, including time spent
in the chooser. The chooser and the write run as one effect; success marks
only that submitted snapshot saved, and later edits stay dirty. A failed write
or a dismissed chooser preserves the board and lets Save retry.

Undo/Redo covers field changes, priority, creation, deletion, and movement.
Changing a field creates one history entry per delivered edit. History holds at
most 50 snapshots and four MiB of conservatively charged task text/key payload
across both stacks; oldest entries retire first. Each snapshot is charged for
its column rows and, separately, for the editor task it retains, whether that
duplicates a live row or is a value no row holds any more. Live drafts, the
saved baseline, and a pending save's captured snapshot are separate retentions
outside this budget, bounded by the 500-task and document decoding limits. Fixed collection overhead is
separately bounded by 500 tasks per snapshot. Oversized snapshots are not
retained, but the live operation still succeeds. New edits clear redo. Undoing
creation never rewinds the next-key allocator, so a different new task receives
a new identity. Opening a document clears both stacks.

Ordinary edits retain sparse Rows generations and update cached payload sizes
from the changed task. Undo/Redo publishes retained earlier generations, so its
explicit snapshot reconciliation can examine the affected columns. Opening and
saving intentionally visit the complete document. Returning via Undo to the
exact saved generation clears the dirty indicator; manually typing equivalent
content still represents a different edited generation.

Closing the native window prompts for unsaved work. Keep editing cancels the
close; Close without saving is explicit; Save and close waits for a successful
write. Failed or canceled saves leave the window and board open for correction
or retry. The decision belongs to the ordinary scoped GUI close registration;
repeated native close requests do not bypass the pending decision.

Ctrl+S saves, Ctrl+Shift+S chooses another destination, and Ctrl+O opens a
project. Ctrl+Z and Ctrl+Shift+Z invoke board Undo/Redo from ordinary controls.
Focused native text inputs keep their standard text-editing undo/redo precedence;
the toolbar buttons explicitly undo or redo board changes. Keyboard semantic
specs dispatch the declared shortcuts; they do not emulate OS keyboard routing.

Opening a replacement disables mutations until its read completes. The save
phases allow editing. Exhausted task identities stop creation with an
explanation while existing tasks remain editable and saveable; IDs never wrap.
