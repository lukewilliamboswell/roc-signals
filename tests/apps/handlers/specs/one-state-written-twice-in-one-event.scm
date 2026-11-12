(test "Handlers — the second of two writes to one state in one event sees the first"
  (steps
    (expect-text (test-id "n") "n=0")
    ; (0 + 1) * 2, one reader woken once.
    (mark-metrics)
    (click (role button :name "n+1, then double"))
    (expect-metric-delta derived_calls_into_roc 1)
    (expect-text (test-id "n") "n=2")
    ; (2 + 1) * 2.
    (mark-metrics)
    (click (role button :name "n+1, then double"))
    (expect-metric-delta derived_calls_into_roc 1)
    (expect-text (test-id "n") "n=6")
  ))
