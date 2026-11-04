(test "t"
  (steps
    (click (role button :name "Go"))
    (mark-metrics)
    (click (role button :name "Go"))
    (expect-metric-delta METRIC 999999)))
