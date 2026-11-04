(test "create 10,000 rows"
  (steps
    (mark-metrics)
    (click (role button :name "Create 10,000 rows"))
    (expect-visible (test-id "row-10000"))))
