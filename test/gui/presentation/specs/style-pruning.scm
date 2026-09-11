(test "an unchanged style signal is pruned before it reaches the host"
  (steps
    (expect-visible (test-id "pruned-row"))
    (expect-visible (text "Styled outside a call"))
    (check (label "Enable action"))
    (mark-metrics)
    (click (test-id "run-action"))
    (expect-visible (text "Runs: 1"))
    (expect-metric-delta set_metadata 0)
    (mark-metrics)
    (click (test-id "run-action"))
    (expect-visible (text "Runs: 2"))
    (expect-metric-delta set_metadata 0)))
