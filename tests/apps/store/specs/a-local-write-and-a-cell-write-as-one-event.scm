(test "Store — one event writes the tenth layer and a cell, composed with also"
  (steps
    ; The tenth layer's reader and cell 3's, and cell 67's reader, which
    ; shares cell 3's bit and is pruned.
    (mark-metrics)
    (click (role button :name "Both"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-metric-delta set_text 2)
    (expect-text (test-id "L10") "L10=1")
    (expect-text (test-id "c3") "c3=1")
    (expect-text (test-id "L9") "L9=0")
  ))
