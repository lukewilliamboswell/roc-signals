(test "New document and Escape shortcuts preserve or discard exactly as requested"
  (steps
    (fill (label "Note text") "A draft")
    (shortcut (test-id "notes-editor") "n" 1)
    (expect-visible (test-id "discard-confirmation"))
    (shortcut (role dialog :name "Discard your changes?") "Escape" 0)
    (expect-absent (test-id "discard-confirmation"))
    (expect-value (label "Note text") "A draft")
    (shortcut (test-id "notes-editor") "n" 1)
    (click (role button :name "Discard changes"))
    (expect-value (label "Note text") "")
    (expect-text (test-id "note-status") "No changes")
    (expect-text (test-id "document-name") "Untitled note")
))
