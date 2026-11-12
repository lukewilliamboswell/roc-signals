(test "Store — a write of one cell ten layers down wakes that cell's one reader"
  (steps
    (expect-text (test-id "c40") "c40=0")
    (mark-metrics)
    (click (role button :name "Bump c40"))
    (expect-metric-delta derived_calls_into_roc 1)
    (expect-metric-delta set_text 1)
    (expect-text (test-id "c40") "c40=1")
    (expect-text (test-id "c41") "c41=0")
  ))
