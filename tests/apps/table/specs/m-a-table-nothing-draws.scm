(test "Table — a write to a table that nothing reads evaluates nothing"
  (steps
    ; A second table of 1,000 rows that no view draws and nothing reads:
    ; a write to it is one cell written and nothing evaluated.
    (mark-metrics)
    (click (role button :name "Touch shadow"))
    (expect-metric-delta derived_calls_into_roc 0)
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta patches_emitted 0)
    (expect-metric-delta set_text 0)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta dirty_source_roots 1)
  )
)
