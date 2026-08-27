(test "replace all 1,000 rows"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role button :name "Create 1,000 rows"))
    (expect-absent (test-id "row-1"))
    (expect-visible (test-id "row-2000"))))
