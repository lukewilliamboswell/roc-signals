(test "remove one row at 1k patches selector memberships locally"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (expect-visible (test-id "row-1000"))
    (click (role button :name "Select row 3"))
    (expect-attr (test-id "row-3") class "danger")
    (expect-attr (test-id "pinned-3") class "danger")
    (mark-metrics)
    (click (role button :name "Remove row 2"))
    (expect-absent (test-id "row-2"))
    ; Only the removed row's two keyed selectors leave the index. The surviving
    ; rows' memberships are neither visited, copied, nor re-registered, so these
    ; counts are the same at 1k and 10k rows.
    (expect-metric-delta selector_registry_visits 2)
    (expect-metric-delta selector_registrations 0)
    (expect-metric-delta selector_key_bytes_copied 0)
    (expect-metric-delta selector_memberships_released 2)
    (expect-metric-delta selector_members_dirtied 0)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta active_graph_records_rebuilt 0)
    ; Surviving selector values are unchanged.
    (expect-attr (test-id "row-3") class "danger")
    (expect-attr (test-id "row-4") class "")
    (expect-attr (test-id "pinned-2") class "")
    ; Selecting another key afterwards dirties only the old members (row 3 and
    ; its pinned duplicate) and the new member; no row closure runs.
    (mark-metrics)
    (click (role button :name "Select row 4"))
    (expect-attr (test-id "row-3") class "")
    (expect-attr (test-id "pinned-3") class "")
    (expect-attr (test-id "row-4") class "danger")
    (expect-metric-delta selector_members_dirtied 3)
    (expect-metric-delta-at-most derived_calls_into_roc 5)
    (expect-metric-delta selector_registry_visits 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_created 0)))
