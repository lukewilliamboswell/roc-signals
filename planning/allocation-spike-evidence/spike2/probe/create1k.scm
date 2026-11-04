(test "create" (steps
 (mark-metrics)
 (click (role button :name "Create 1,000 rows"))
 (mark-metrics)
 (expect-visible (test-id "row-1000"))))
