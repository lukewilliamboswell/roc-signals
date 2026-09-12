(test "append one row at 10k registers only the new memberships"
  (steps
    (click (role button :name "Create 10,000 rows"))
    (expect-visible (test-id "row-10000"))
    (click (role button :name "Select row 3"))
    (expect-attr (test-id "row-3") class "danger")
    (mark-metrics)
    (click (role button :name "Append one row"))
    (expect-visible (test-id "row-10001"))
    ; The appended row's two keyed selectors are the only registrations, and
    ; the only key bytes copied are its key twice. Registry visits cover the
    ; appended graph records, not the surviving rows.
    (expect-metric-delta-at-most selector_registry_visits 8)
    (expect-metric-delta selector_registrations 2)
    (expect-metric-delta selector_key_bytes_copied 10)
    (expect-metric-delta selector_memberships_released 0)
    (expect-metric-delta selector_members_dirtied 0)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta active_graph_records_rebuilt 0)
    (expect-attr (test-id "row-3") class "danger")
    (expect-attr (test-id "row-10001") class "")
    ; The new membership is live: selecting it dirties the old members and it.
    (mark-metrics)
    (click (role button :name "Select row 10001"))
    (expect-attr (test-id "row-3") class "")
    (expect-attr (test-id "pinned-3") class "")
    (expect-attr (test-id "row-10001") class "danger")
    (expect-metric-delta selector_members_dirtied 3)
    (expect-metric-delta-at-most derived_calls_into_roc 5)
    (expect-metric-delta selector_registry_visits 0)
    (expect-metric-delta rows_created 0)))
