(scenario "delete-dialog"
  :window "1200x820"
  ; The delete confirmation is a modal: it must be admitted, laid out inside the
  ; window, and it must be able to refuse. Cancelling has to leave every task in
  ; place, which is the assertion a screenshot of the dialog cannot make.
  (steps
    (expect-count "task-" 8)
    (click (test-id "edit-task-6"))
    (wait 400)
    (click (role button :name "Delete task"))
    (wait 500)
    (snapshot "delete-dialog")
    (click (role button :name "Cancel deletion"))
    (wait 500)
    (expect-count "task-" 8)
    (expect-absent (text "\"Delete this task?\""))))
