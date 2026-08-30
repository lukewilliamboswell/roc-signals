(test "remove row"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role link :name "Remove row 2"))
    (expect-absent (test-id "row-2"))))
