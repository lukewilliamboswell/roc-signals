(test "Canceling the save chooser during close retains the board and permits editing"
 (steps
  (request-window-close)
  (stub-file-choice "board-save-path" (canceled))
  (click (role button :name "Save and close"))
  (expect-window-closed false)
  (expect-visible (test-id "board-close"))
  (click (role button :name "Keep editing"))
  (fill (label "Task title") "Still editable")
  (expect-value (label "Task title") "Still editable")
  (expect-text (test-id "board-status") "Unsaved changes")
 ))
