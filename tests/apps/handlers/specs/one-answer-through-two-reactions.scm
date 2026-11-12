(test "Handlers — one answer runs two reactions in order and wakes the readers of both writes"
  (steps
    (expect-pending-effects 1)
    (expect-text (test-id "count") "count=0")
    (mark-metrics)
    (run-effect 1)
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-text (test-id "count") "count=1")
    (expect-text (test-id "log") "log=tick;")
  ))
