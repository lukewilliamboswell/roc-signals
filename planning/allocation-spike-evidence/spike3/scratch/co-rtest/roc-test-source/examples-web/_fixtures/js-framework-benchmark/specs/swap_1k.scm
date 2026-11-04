(test "swap rows"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role button :name "Swap Rows"))
    (expect-visible (test-id "row-999"))
    (expect-metric-delta rows_render_roots_moved 2)
    (expect-metric-delta move_before 2)
    (expect-metric-delta stream_nodes_scanned 0)
    (expect-metric-delta render_indexes_refreshed 0)
    (expect-metric-delta active_graph_records_rebuilt 0)))
