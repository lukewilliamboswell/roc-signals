(test "Store — a cell read at the root, five layers down and ten layers down wakes those three readers"
  (steps
    (expect-text (test-id "root-c7") "root-c7=0")
    ; Its three readers, and cell 71's reader, which shares its signature
    ; bit (7 + 64) and is pruned: four evaluations, three texts.
    (mark-metrics)
    (click (role button :name "Bump c7"))
    (expect-metric-delta derived_calls_into_roc 4)
    (expect-metric-delta set_text 3)
    (expect-text (test-id "root-c7") "root-c7=1")
    (expect-text (test-id "mid-c7") "mid-c7=1")
    (expect-text (test-id "c7") "c7=1")
    (expect-text (test-id "c71") "c71=0")
  ))
