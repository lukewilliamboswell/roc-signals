(test "select row"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (click (role link :name "Select row 2"))
    (mark-metrics)
    (click (role link :name "Select row 3"))
    (expect-attr (test-id "row-2") class "")
    (expect-attr (test-id "row-3") class "danger")
    (expect-metric-delta selector_members_dirtied 2)
    (expect-metric-delta derived_calls_into_roc 4)))
