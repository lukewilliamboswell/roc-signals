(test "t"
  (steps
    (mark-metrics)
    (click (role button :name "Create 1,000 rows"))
    (expect-metric-delta allocs_this_event 999999)))
