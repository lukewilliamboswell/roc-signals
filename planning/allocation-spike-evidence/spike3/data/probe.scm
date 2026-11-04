(test "probe"
  (steps
    (click (role button :name "Increment"))
    (mark-metrics)
    (click (role button :name "Increment"))
    (expect-metric-delta METRIC 999999)))
