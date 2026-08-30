(test "swap rows"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role button :name "Swap Rows"))
    (expect-visible (test-id "row-999"))))
