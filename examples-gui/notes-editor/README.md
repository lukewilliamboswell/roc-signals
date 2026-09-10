# Notes

A plain-text editor built with public `Gui`, `Ui`, `Signal`, and `Files` APIs.
It provides multiline editing, native Open/Save As choosers, real UTF-8 file
persistence, word and character counts, exact dirty tracking, and keyboard
shortcuts. A document's displayed name follows its selected file path.

Run from the repository root after preparing the GUI host as described in
[contributing](../../www/content/docs/contributing.md#native-gui-platform-spike):

```sh
roc build --opt=dev examples-gui/notes-editor/main.roc --output=.test-out/Notes
.test-out/Notes
python3 scripts/spec_driver.py .test-out/Notes examples-gui/notes-editor/specs
roc test examples-gui/notes-editor/main.roc
```

Control+N creates a document, Control+O opens one, Control+S saves, and
Control+Shift+S chooses a new destination. Escape cancels an operation or closes
the discard confirmation. Native editor selection, movement, and clipboard
bindings retain their usual behavior. Paragraphs wrap to the viewport; Control+Z
undoes typing and Control+Shift+Z or Control+Y redoes it. The editor owns bounded
history (128 boundaries and 8 MiB), cleared on a new document lifetime even when
its text equals the preceding document.

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
focused buttons; Escape keeps the current draft. Closing an edited document
asks whether to Save and close, Discard and close, or Keep editing. A closing
save freezes editing and waits for successful completion; cancellation or failure
keeps the window and draft open. Closing during another file operation asks the
user to finish or cancel it first.
Statistics use the pinned [Roc Unicode package](../../vendor/unicode/README.md).
Characters are Unicode 17 extended grapheme clusters, including whitespace:
`é` and `é` each count as one, as do joined emoji and flag sequences; CRLF
counts as one cluster. Words are default Unicode word segments containing a
letter or number. Punctuation, whitespace, and emoji-only segments are excluded.
This is Unicode's default segmentation, not language-specific dictionary word
counting. Original text is never normalized or rewritten to compute statistics.
The scans use ranges and iterators rather than per-character lists; counting
still visits the complete changed document. GPUI retains responsibility for
native shaping, caret interaction, and IME behavior.

`Session.roc` holds the pure document operation state machine, including the
editable body and the `document_generation` that identifies the editor's
lifetime. Keeping them in one state is deliberate: a document replacement
advances the lifetime and installs its text as a single settled value, so the
editor can never mount against another document's text. Typing, saving, and the
temporary unavailability during a chooser leave the lifetime alone, which is
what preserves native selection and undo history while a document is edited.
`Workflow.roc` observes only its phase to start tasks, and task results enter
ordinary shared engine propagation. The native semantic specs supply typed task outcomes to
check cancellation, failures, stale results, repeat saves, and snapshot ownership
deterministically. Filesystem worker tests and actual GPUI interaction tests
cover the native boundaries separately.
