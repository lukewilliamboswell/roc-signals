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
Pointer drops and the explicit controls use the same domain reducer. The old card scope is disposed and
a new card scope is created at the destination; the application does not claim
that independent keyed-list sites transfer scopes.

Build and run with the [GUI contributor workflow](../../www/content/docs/contributing.md#native-gui-platform-spike).
Native semantic journeys live in `specs/`; they check editing, filtering,
repeated creation, dialog dismissal and deletion, selection, drops, movement, and structural
work. These specs model interaction semantics and do not establish actual
keyboard, focus, composition, or accessibility behavior in a Wayland session.

Collaboration, notifications, and remote synchronization are outside
this example. Deletion uses a scoped native dialog with Cancel and Escape.
Semantic drop tests exercise the shared action path; the native capability
fixtures separately cover pointer gesture delivery and stale drag rejection.

## Documents and undo

The document stores version 1 JSON, explicit task identities, ordered columns,
and the next generated identity. Loading rejects malformed JSON, unsupported
versions, duplicate keys across columns, exhausted identities, oversized fields,
and boards over 500 tasks. Validation completes before replacing live data.
The encoded file must fit the native Files one-MiB limit. Task titles support
512 UTF-8 bytes, notes 8192, assignees 128, and keys 256. These are byte bounds,
not character counts. A refused field edit leaves its previous value and explains
the limit. Save reports an oversized encoded document without writing anything.

Open asks before replacing an unsaved board. Cancel or a failed read leaves the
board and its previous path intact, even after choosing to discard. Saving holds
an immutable snapshot from the moment Save was requested, including time spent
in the chooser. Editing can continue while choosing a destination or writing;
success marks only that submitted snapshot saved. Later edits stay dirty. A
failed or canceled write preserves the board and lets Save retry; cancellation
does not undo a filesystem rename that already committed.

Undo/Redo covers field changes, priority, creation, deletion, and movement.
Changing a field creates one history entry per delivered edit. History holds at
most 50 snapshots and four MiB of conservatively charged task text/key payload
across both stacks; oldest entries retire first. Fixed collection overhead is
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

Window-close protection is integrated through the shared native close capability
when available; document replacement confirmation is already part of this app.
