(test "Kanban board — reorder inside a column"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Move right: Draft onboarding copy"))

    ; reorder inside a column
    (mark-metrics)
    (click (role button :name "Move up: Draft onboarding copy"))
    ; A within-column reorder reuses every row in the column.
    (expect-metric-delta rows_reused 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-position-Draft onboarding copy") "Position 1 of 2 in In Progress")
    (expect-text (test-id "card-position-Ship search filters") "Position 2 of 2 in In Progress")
    (expect-disabled (role button :name "Move up: Draft onboarding copy") true)
    (expect-disabled (role button :name "Move down: Draft onboarding copy") false)
    (expect-disabled (role button :name "Move up: Ship search filters") false)
    (expect-disabled (role button :name "Move down: Ship search filters") true)
    (mark-metrics)
    (click (role button :name "Move down: Draft onboarding copy"))
    (expect-metric-delta rows_reused 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-position-Ship search filters") "Position 1 of 2 in In Progress")
    (expect-text (test-id "card-position-Draft onboarding copy") "Position 2 of 2 in In Progress")
  )
)
