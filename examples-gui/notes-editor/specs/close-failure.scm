(test "A failed closing save keeps the draft editable and permits retry"
  (steps
    (fill (label "Note text") "Do not lose this")
    (request-window-close)
    (stub-file-choice "notes-save-path" (chosen "/tmp/Ideas café.txt"))
    (stub-file-reject "notes-write" :kind permission-denied :detail "destination")
    (click (role button :name "Save and close"))
    (expect-window-closed false)
    (expect-value (label "Note text") "Do not lose this")
    (expect-disabled (label "Note text") false)
    (expect-text (test-id "note-problem") "Permission denied: destination")
    (request-window-close)
    (click (role button :name "Keep editing"))
    (expect-window-closed false)))
