# Launch Board

A small team task board with three columns, live detail editing, search, task
creation and confirmed deletion, drag movement, and explicit move controls. The seeded project is ready
to explore without an account or a service. Changes live for the current session.

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

Persistence, collaboration, notifications, and remote synchronization are outside
this example. Deletion uses a scoped native dialog with Cancel and Escape.
Semantic drop tests exercise the shared action path; the native capability
fixtures separately cover pointer gesture delivery and stale drag rejection.
