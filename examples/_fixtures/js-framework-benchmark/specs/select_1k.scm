(test "select row"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role link :name "Select row 2"))
    (expect-attr (test-id "row-2") class "danger")))
