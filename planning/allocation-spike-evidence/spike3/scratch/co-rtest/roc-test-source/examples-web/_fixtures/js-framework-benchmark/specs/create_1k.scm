(test "create 1,000 rows"
  (steps
    (mark-metrics)
    (click (role button :name "Create 1,000 rows"))
    (expect-visible (test-id "row-1000"))))
