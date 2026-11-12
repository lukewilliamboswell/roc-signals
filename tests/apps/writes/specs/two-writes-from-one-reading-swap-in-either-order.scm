(test "Writes — two cells swapped by one decision: both writes come from one reading, so the list's order does not matter"
  (steps
    (expect-text (test-id "left") "left=1")
    (expect-text (test-id "right") "right=2")
    ; The two cells' readers, the site that follows `left`, and in its
    ; follow-up turn the log's reader.
    (mark-metrics)
    (click (role button :name "Swap"))
    (expect-metric-delta derived_calls_into_roc 4)
    (expect-text (test-id "left") "left=2")
    (expect-text (test-id "right") "right=1")
    (mark-metrics)
    (click (role button :name "Swap, other order"))
    (expect-metric-delta derived_calls_into_roc 4)
    (expect-text (test-id "left") "left=1")
    (expect-text (test-id "right") "right=2")
  ))
