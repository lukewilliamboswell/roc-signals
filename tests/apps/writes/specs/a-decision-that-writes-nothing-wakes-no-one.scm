(test "Writes — the cells written are the ones the decision returns: one that returns none wakes no one"
  (steps
    (mark-metrics)
    (click (role button :name "Grow left"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta dirty_source_roots 2)
    (expect-text (test-id "left") "left=2")
    (click (role button :name "Grow left"))
    (expect-text (test-id "left") "left=3")
    ; At 3 the decision returns no write: no reader runs and no layer is dirty.
    (mark-metrics)
    (click (role button :name "Grow left"))
    (expect-metric-delta derived_calls_into_roc 0)
    (expect-metric-delta dirty_source_roots 0)
    (expect-metric-delta patches_emitted 0)
    (expect-text (test-id "left") "left=3")
  ))
