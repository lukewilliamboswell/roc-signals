(test "select row"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (click (role link :name "Select row 2"))
    (mark-metrics)
    (click (role link :name "Select row 3"))
    (expect-attr (test-id "row-2") class "")
    (expect-attr (test-id "row-3") class "danger")
    ; The keyed selector dirties the old and new memberships only. Its two Roc
    ; calls directly produce the old and new class values; none of the other
    ; 998 row renderers runs.
    (expect-metric-delta selector_members_dirtied 2)
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta each_syncs 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta active_graph_records_rebuilt 0)
    (expect-metric-delta signal_record_table_rebuilt 0)
    (expect-metric-delta stream_nodes_scanned 0)))
