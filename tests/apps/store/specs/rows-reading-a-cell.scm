(test "Store — rows ten layers down read a cell with no lift, and a write of it re-evaluates each"
  (steps
    (expect-text (test-id "row") "r1:0")
    ; Cell 50's own reader and its five rows; no cell shares its bit.
    (mark-metrics)
    (click (role button :name "Bump c50"))
    (expect-metric-delta derived_calls_into_roc 6)
    (expect-metric-delta set_text 6)
    (expect-text (test-id "c50") "c50=1")
    (expect-text (test-id "row") "r1:1")
  ))
