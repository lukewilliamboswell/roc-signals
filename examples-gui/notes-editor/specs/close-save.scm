(test "Save and close waits for success without losing the submitted note"
  (steps
    (fill (label "Note text") "First revision")
    (request-window-close)
    (expect-window-closed false)
    (expect-visible (test-id "close-confirmation"))
    (request-window-close)
    (stub-file-choice "notes-save-path" (chosen "/tmp/Ideas café.txt"))
    (click (role button :name "Save and close"))
    (expect-absent (test-id "close-confirmation"))
    (expect-window-closed true)))
