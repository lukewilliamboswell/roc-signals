(test "A failed closing save keeps the draft editable and permits retry"
  (steps
    (fill (label "Note text") "Do not lose this")
    (request-window-close)
    (click (role button :name "Save and close"))
    (resolve-task "notes-save-path" "6:files16:chosen20:/tmp/Ideas café.txt")
    (reject-task "notes-write" "6:files117:permission-denied11:destination")
    (expect-window-closed false)
    (expect-value (label "Note text") "Do not lose this")
    (expect-disabled (label "Note text") false)
    (expect-text (test-id "note-problem") "Permission denied: destination")
    (request-window-close)
    (click (role button :name "Keep editing"))
    (expect-window-closed false)))
