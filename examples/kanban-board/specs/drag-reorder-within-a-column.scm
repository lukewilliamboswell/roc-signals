(test "Kanban board — drag a card after its neighbour"
  (steps
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (pointer-move (role region :name "Design login screen") :at 50 75)
    (mark-metrics)
    (pointer-up (role region :name "Design login screen") :at 50 75)
    (expect-metric-delta rows_moved 1)
    (expect-metric-delta rows_updated 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-position-Design login screen") "1 of 2 in Backlog")
    (expect-text (test-id "card-position-Draft onboarding copy") "2 of 2 in Backlog")))
