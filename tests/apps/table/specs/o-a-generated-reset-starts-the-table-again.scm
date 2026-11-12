(test "Table — a group's generated reset starts its table again as a whole rewrite: every view rebuilds, and the next row written is absorbed"
  (steps
    ; The group is the to-dos and the next key. Its reset puts the table
    ; back to the rows it was described with, none, through the table's
    ; own cell, so it is a whole rewrite: both lists rebuild from an empty
    ; table (no placement) and their 35 rows are removed. The two readers
    ; of the table run; nothing reads the next key.
    (mark-metrics)
    (click (role button :name "Start again"))
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta set_text 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 35)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta dirty_source_roots 2)
    (expect-text (test-id "count") "Rows: 0")
    (expect-text (test-id "row0") "Row 0: gone")
    (expect-text (test-id "main") "")
    (expect-text (test-id "done") "")
    ; The next key started again too, so the row added now is row 0: one
    ; placement in each list, the two readers, and the new row's 14 holes.
    (mark-metrics)
    (click (role button :name "Add"))
    (expect-metric-delta derived_calls_into_roc 18)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "count") "Rows: 1")
    (expect-text (test-id "row0") "Row 0: New 0")
    (expect-text (test-id "main") "0:0:0 ")
    (expect-text (test-id "done") "")
  )
)
