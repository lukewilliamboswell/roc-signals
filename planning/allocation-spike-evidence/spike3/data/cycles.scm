(test "cycles"
  (steps
    (click (role button :name "Toggle"))
    (click (role button :name "Toggle"))
    (mark-metrics)
    (click (role button :name "Toggle"))
    (click (role button :name "Toggle"))
    (expect-metric-delta host_retained_bytes_delta 999999)))
