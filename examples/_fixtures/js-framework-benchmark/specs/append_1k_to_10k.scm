(test "append 1,000 rows to 10,000 rows"
  (steps
    (click (role button :name "Create 10,000 rows"))
    (mark-metrics)
    (click (role button :name "Append 1,000 rows"))
    (expect-visible (test-id "row-11000"))))
