(test "clear 10,000 rows"
  (steps
    (click (role button :name "Create 10,000 rows"))
    (mark-metrics)
    (click (role button :name "Clear"))
    (expect-absent (test-id "row-1"))))
