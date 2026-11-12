(test "Kanban board — per row edit does not disturb siblings"
  (steps
    ; Bring the page to the state this spec starts from.
    (mark-metrics)
    (click (role button :name "Move right: Draft onboarding copy"))
    (mark-metrics)
    (click (role button :name "Move up: Draft onboarding copy"))
    (mark-metrics)
    (click (role button :name "Move down: Draft onboarding copy"))
    ; per row edit does not disturb siblings
    (mark-metrics)
    (click (role button :name "Flag: Ship search filters"))
    ; A flag is a write of the card's own row: its column's view wakes that
    ; row and leaves its sibling alone, both in place. A view compares no
    ; list of rows, so it counts none as reused.
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 1)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-flags-Ship search filters") "1 flag")
    (expect-absent (test-id "card-flags-Draft onboarding copy"))
    (expect-absent (test-id "card-flags-Design login screen"))
    (expect-text (test-id "card-position-Ship search filters") "1 of 2 in In Progress")
  )
)
