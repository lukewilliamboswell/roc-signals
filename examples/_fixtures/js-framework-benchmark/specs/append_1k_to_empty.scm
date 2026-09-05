(test "append 1,000 rows to an empty table"
  (steps
    (mark-metrics)
    (click (role button :name "Append 1,000 rows"))
    (expect-visible (test-id "row-1000"))
    (expect-metric-delta rows_created 1000)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_render_roots_moved 0)
    (expect-metric-delta render_indexes_refreshed 0)
    (expect-metric-delta active_graph_records_rebuilt 0)))
