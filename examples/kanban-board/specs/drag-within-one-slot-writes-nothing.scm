(test "Kanban board — moving inside one drop gap writes nothing"
  (steps
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (pointer-move (role region :name "Ship search filters") :at 50 25)
    (mark-metrics)
    (pointer-move (role region :name "Ship search filters") :at 50 30)
    (expect-metric-delta dirty_source_roots 0)
    (expect-metric-delta patches_emitted 0)
    (pointer-up (role region :name "Ship search filters") :at 50 30)))
