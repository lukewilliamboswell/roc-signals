(test "Domain history and deletion retire the editors they replace"
  (steps
    (click (test-id "edit-task-1"))
    (fill (label "Task title") "Renamed")

    ; Undo restores a snapshot the native inputs never produced, so it may not
    ; leave the user able to undo back into the replaced value natively.
    (mark-metrics)
    (click (role button :name "Undo"))
    (expect-value (label "Task title") "Sketch the welcome screen")
    (expect-metric-delta scopes_created 4)
    (expect-metric-delta scopes_disposed 4)

    (mark-metrics)
    (click (role button :name "Redo"))
    (expect-value (label "Task title") "Renamed")
    (expect-metric-delta scopes_created 4)
    (expect-metric-delta scopes_disposed 4)

    ; Deleting the edited task disposes the detail panel outright, which
    ; releases the native inputs and the task payload they were holding.
    (click (role button :name "Delete task"))
    (click (role button :name "Confirm delete"))
    (expect-absent (test-id "task-1"))
    (expect-text (test-id "task-detail") "Task detailsSelect a task to edit its details.")

    ; Selecting again builds a new editor rather than reviving the old one.
    (click (test-id "edit-task-2"))
    (expect-value (label "Task title") "Write the empty-state copy")))
