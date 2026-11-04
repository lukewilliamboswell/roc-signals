(test "swap rows"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role button :name "Swap Rows"))
    (expect-metric-delta allocs_this_event 99999999)))
