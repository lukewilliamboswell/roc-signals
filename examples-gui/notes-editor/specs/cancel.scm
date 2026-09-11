(test "Dismissed choosers preserve the draft and the document name"
  (steps
    (stub-file-choice "notes-open" (canceled))
    (shortcut (test-id "notes-editor") "o" 1)
    (expect-text (test-id "note-status") "No changes")
    (fill (label "Note text") "Current draft")
    (expect-text (test-id "document-name") "Untitled note")
    (stub-file-choice "notes-save-path" (canceled))
    (shortcut (test-id "notes-editor") "s" 1)
    (expect-value (label "Note text") "Current draft")
    (expect-text (test-id "note-status") "Unsaved changes")
    (expect-text (test-id "document-name") "Untitled note")
))
