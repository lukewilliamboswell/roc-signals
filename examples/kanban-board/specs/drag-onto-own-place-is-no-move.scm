(test "Kanban board — dropping into its own place edits no card"
  (steps
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (mark-metrics)
    (pointer-up (test-id "grip-Draft onboarding copy"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "card-position-Draft onboarding copy") "1 of 2 in Backlog")
    (expect-text (test-id "drag-status") "Ready to move cards")))
