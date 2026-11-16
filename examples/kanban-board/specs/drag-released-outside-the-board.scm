(test "Kanban board — releasing outside abandons the drag"
  (steps
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (pointer-move (label "Filter cards"))
    (expect-text (test-id "drag-status") "Moving Draft onboarding copy outside the board")
    (mark-metrics)
    (pointer-up (label "Filter cards"))
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "card-position-Draft onboarding copy") "1 of 2 in Backlog")
    (expect-text (test-id "drag-status") "Ready to move cards")))
