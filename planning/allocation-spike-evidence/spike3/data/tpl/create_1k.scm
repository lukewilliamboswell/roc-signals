(test "t"
  (steps
    (mark-metrics)
    (click (role button :name "Create 1,000 rows"))
    (expect-metric-delta METRIC 999999)))
