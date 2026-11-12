(test "Writes — a decision receives the event's payload"
  (steps
    (mark-metrics)
    (fill (label "Echo") "hi")
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-text (test-id "echo") "echo=hi")
    (expect-value (label "Echo") "hi")
  ))
