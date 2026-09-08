# Notes

A native notes editor example built with public `Gui`, `Ui`, and `Signal` APIs.
The initial slice provides a document title, an editable text draft, live word
and character counts, exact unsaved-change tracking, and confirmed discard.
Title and body are independent sources; discard replaces both in one action.

This slice uses the current single-line GUI input. Multiline editing, native
Open/Save dialogs, and real file persistence are still required before the
document workflow is complete. Closing the process currently loses the draft.
The app does not present an in-memory operation as saving a file.

From the repository root, prepare the GUI host as described in
[contributing](../../www/content/docs/contributing.md#native-gui-platform-spike),
then build and run:

```sh
roc build examples-gui/notes-editor/main.roc --output=.test-out/Notes
.test-out/Notes
python3 scripts/spec_driver.py .test-out/Notes examples-gui/notes-editor/specs
roc test examples-gui/notes-editor/Document.roc
```

For an interaction check, change both fields, cancel Revert, then confirm it.
Cancel must preserve the complete draft; confirm must restore both fields and
the summary together. Re-entering the initial text also clears the dirty status.
These native semantic specs exercise the shared engine. Actual GPUI keyboard,
focus, selection, and composition behavior require GUI interaction checks.

The character count measures Unicode scalar values, not grapheme clusters.
Words are runs separated by ASCII whitespace, including tabs and line breaks.
