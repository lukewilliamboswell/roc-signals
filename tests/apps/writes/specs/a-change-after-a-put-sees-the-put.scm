(test "Writes — one cell written twice by one decision: a change after a put is applied to what was put"
  (steps
    (mark-metrics)
    (click (role button :name "Set then add"))
    (expect-metric-delta derived_calls_into_roc 1)
    (expect-text (test-id "total") "total=11")
  ))
