(scenario "minimum-window"
  :window "360x240"
  ; The smallest window the host permits. The board must still mount, keep its
  ; seeded tasks, and accept a selection there; the layout at that size is a
  ; separate diagnostic.
  (steps
    (expect-count "task-" 8)
    (click (test-id "edit-task-3"))
    (wait 500)
    (expect-selected (test-id "task-3") true)))
