(test "remove row"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role link :name "Remove row 2"))
    (expect-absent (test-id "row-2"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_render_roots_moved 0)
    (expect-metric-delta stream_nodes_scanned 0)
    (expect-metric-delta render_indexes_refreshed 0)
    (expect-metric-delta active_graph_records_rebuilt 0)))
