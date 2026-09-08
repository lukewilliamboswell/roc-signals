# Notes

A plain-text editor built with public `Gui`, `Ui`, `Signal`, and `Files` APIs.
It provides multiline editing, native Open/Save As choosers, real UTF-8 file
persistence, word and character counts, exact dirty tracking, and keyboard
shortcuts. A document's displayed name follows its selected file path.

Run from the repository root after preparing the GUI host as described in
[contributing](../../www/content/docs/contributing.md#native-gui-platform-spike):

```sh
roc build --target=x64glibc --opt=dev examples-gui/notes-editor/main.roc --output=.test-out/Notes
.test-out/Notes
python3 scripts/spec_driver.py .test-out/Notes examples-gui/notes-editor/specs
roc test examples-gui/notes-editor/main.roc
```

Control+N creates a document, Control+O opens one, Control+S saves, and
Control+Shift+S chooses a new destination. Escape cancels an operation or closes
the discard confirmation. Native editor selection, movement, and clipboard
bindings retain their usual behavior.

Try opening a UTF-8 file, editing several lines, saving it, and using Revert
changes after another edit. Revert restores the last accepted file snapshot.
New and Open ask before replacing unsaved text; canceling the confirmation or
file chooser preserves it. Errors leave the draft available for retry.

A write captures its complete text before background work begins. Editing can
continue while it saves; completion accepts the submitted snapshot, so later
edits remain dirty. File operations are serialized for this document. Canceling
a save cannot undo a rename that has already committed. See the
[native Files contract](../../docs/native-gui-protocol.md) for limits and path
handling. Text files are limited to one MiB; oversized editor replacements are
refused as complete operations. Files and filenames must be valid UTF-8.

The discard dialog focuses Keep editing, contains Tab/Shift-Tab navigation,
and restores the prior live control when dismissed. Enter/Space activate
focused buttons; Escape keeps the current draft. Closing the application still
discards unsaved changes; there is no window-close confirmation yet.
Character counts measure Unicode scalar values, and words are runs separated
by ASCII whitespace, including tabs and line breaks.

`Session.roc` holds the pure document operation state machine. `Workflow.roc`
observes only its phase to start tasks, and task results enter ordinary shared
engine propagation. The native semantic specs supply typed task outcomes to
check cancellation, failures, stale results, repeat saves, and snapshot ownership
deterministically. Filesystem worker tests and actual GPUI interaction tests
cover the native boundaries separately.
