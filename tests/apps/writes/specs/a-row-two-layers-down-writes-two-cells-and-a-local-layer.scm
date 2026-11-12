(test "Writes — a row two local layers down writes two cells with no lift, and a local layer, as one event"
  (steps
    (mark-metrics)
    (click (role button :name "Deep r2"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta set_text 3)
    (expect-text (test-id "clicks") "clicks=1")
    (expect-text (test-id "log") "log=r2")
    (expect-text (test-id "total") "total=1")
    (expect-text (test-id "left") "left=1")
  ))
