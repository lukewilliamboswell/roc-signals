(test "Kanban board — drag a card to the end of another column"
  (steps
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (pointer-move (test-id "lane-end-progress"))
    (expect-text (test-id "drag-status") "Moving Draft onboarding copy to In Progress, place 2")
    (mark-metrics)
    (pointer-up (test-id "lane-end-progress"))
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-text (test-id "card-position-Draft onboarding copy") "2 of 2 in In Progress")
    (expect-text (test-id "card-position-Design login screen") "1 of 1 in Backlog")
    (expect-text (test-id "drag-status") "Ready to move cards")))
