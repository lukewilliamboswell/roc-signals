(test "Kanban board — per row edit does not disturb siblings"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Move right: Draft onboarding copy"))
    (mark-metrics)
    (click (role button :name "Move up: Draft onboarding copy"))
    (mark-metrics)
    (click (role button :name "Move down: Draft onboarding copy"))
    ; per row edit does not disturb siblings
    (mark-metrics)
    (click (role button :name "Flag: Ship search filters"))
    (expect-metric-delta rows_reused 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "card-flags-Ship search filters") "1 flag")
    (expect-absent (test-id "card-flags-Draft onboarding copy"))
    (expect-absent (test-id "card-flags-Design login screen"))
    (expect-text (test-id "card-position-Ship search filters") "1 of 2 in In Progress")
  )
)
