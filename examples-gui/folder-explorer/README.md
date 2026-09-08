# Folder Explorer

Rows show paths relative to the chosen folder, while semantic labels, selection,
filtering, and the details panel retain the full path. The 64-pixel virtual rows
leave room for the field padding and selection border.

Browse a deterministic sample workspace, or choose a real local folder for a
bounded background metadata scan. Filter paths, sort by name or file size, and
select a row to inspect its metadata. The result list renders a visible range
while retaining identity for surviving keyed rows. Ctrl+O opens the chooser,
F5 rescans the current folder, and Escape cancels the active operation.

The source badge identifies sample data and real folders explicitly. Choosing,
rescanning, cancellation, and errors retain the last successful dataset. A
successful rescan refreshes the selected path's metadata or clears a selection
whose path disappeared. Filtering does not clear selection.

File work uses the public `Files` tasks and `Signal.cancel`; the app has no native
host routes. Folder chooser dismissal is a successful canceled choice, while an
explicit cancellation reaches a terminal task error. Late canceled results
cannot replace newer state. Native scans are bounded at 10,000 entries, 64
directory levels, and four MiB of aggregate paths; symlinks and special entries
remain visible without traversal. A scan is a complete observation, not an atomic
filesystem snapshot. Concurrent changes or any exceeded bound can refuse it.

Selection changes update only their derived presentation. Filtering, sorting,
and completed scans are explicit operations over the current dataset. An
ancestor-owned session keeps rows, provenance, operation state, and selection
together; command-owned updates receive the settled session without an observer
feedback dependency. The pure `Explorer` module owns ordering, filtering, totals,
and selection reconciliation.

The semantic specs cover sample browsing, selection locality, complete scans,
metadata refresh, removed selections, chooser dismissal, errors, cancellation,
and stale results. Build and run through the GUI workflow in
[`contributing.md`](../../www/content/docs/contributing.md).
