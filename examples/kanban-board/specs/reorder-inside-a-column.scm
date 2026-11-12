(test "Kanban board — reorder inside a column"
  (steps
    ; Bring the page to the state this spec starts from.
    (mark-metrics)
    (click (role button :name "Move right: Draft onboarding copy"))
    ; reorder inside a column
    (mark-metrics)
    (click (role button :name "Move up: Draft onboarding copy"))
    ; A within-column reorder keeps every row in the column: the two cards
    ; exchange places, which the column's view applies as one row moved and
    ; the two rows written woken. A view compares no list of rows, so it
    ; counts none as reused.
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_moved 1)
    (expect-metric-delta rows_updated 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-position-Draft onboarding copy") "1 of 2 in In Progress")
    (expect-text (test-id "card-position-Ship search filters") "2 of 2 in In Progress")
    (expect-disabled (role button :name "Move up: Draft onboarding copy") true)
    (expect-disabled (role button :name "Move down: Draft onboarding copy") false)
    (expect-disabled (role button :name "Move up: Ship search filters") false)
    (expect-disabled (role button :name "Move down: Ship search filters") true)
    (mark-metrics)
    (click (role button :name "Move down: Draft onboarding copy"))
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_moved 1)
    (expect-metric-delta rows_updated 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-position-Ship search filters") "1 of 2 in In Progress")
    (expect-text (test-id "card-position-Draft onboarding copy") "2 of 2 in In Progress")
  )
)
