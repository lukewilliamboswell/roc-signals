(test "Kanban board — touch cancellation leaves every card in place"
  (steps
    (pointer-down (test-id "grip-Draft onboarding copy") :pointer touch :id 2)
    (pointer-move (role region :name "Ship search filters") :at 50 75 :id 2)
    (mark-metrics)
    (pointer-cancel :id 2)
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "card-position-Draft onboarding copy") "1 of 2 in Backlog")
    (expect-text (test-id "card-position-Ship search filters") "1 of 1 in In Progress")
    (expect-text (test-id "drag-status") "Ready to move cards")))
