(test "Handlers — one event writing two states wakes the readers of both and no one else"
  (steps
    (mark-metrics)
    (click (role button :name "Both"))
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-text (test-id "date") "date=none!")
    (expect-text (test-id "other") "other=1")
    (expect-text (test-id "picker") "picker=open")
  ))
