(test "Services — mount requests do not mark a batch; later changes do"
  (steps
    (expect-transitions 0)
    (mark-metrics)
    (click (role button :name "Animate turn"))
    (expect-transitions 1)
    (expect-transition 1 "services")
    (expect-metric-delta view_transitions 1)
    (click (role button :name "Animate turn"))
    (expect-transitions 2)
    (expect-transition 2 "services")))
