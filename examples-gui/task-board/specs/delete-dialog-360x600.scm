(scenario "delete-dialog-360x600"
  :window "360x600"
  ; The board's own confirmations were never checked at a small size. Clicking the
  ; dialog's own action is what proves it was admitted and can refuse. Whether it
  ; is laid out inside the window is left to the capture: a dialog is lifted into
  ; its own render layer and the bounds probe records nothing for it, which is a
  ; gap in this harness rather than a property of the dialog.
  (steps
    (click (test-id "edit-task-6"))
    (wait 400)
    (click (role button :name "Delete task"))
    (wait 500)
    (click (role button :name "Cancel deletion"))
    (wait 500)
    (expect-count "task-" 8)
    (expect-absent (text "Delete this task?"))))
