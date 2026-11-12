(test "Workers — a timeout expires only when the spec says so"
  (steps
    ; "Slow" runs spin as a task with a 50 ms timeout. A spec's time is manual: the
    ; job waits, and run-effect runs it to completion however long it takes
    ; (these rounds take far longer than 50 ms).
    (fill (label "Rounds") "100000000")
    (click (role button :name "Slow"))
    (expect-pending-work "test.roc-signals/slow" 1)
    (run-effect 1)
    (expect-text (test-id "log") "slow:spun 100000000 603")
    ; time-out-work expires the next one: Timeout, and it never runs.
    (click (role button :name "Slow"))
    (mark-metrics)
    (time-out-work 2)
    (expect-metric-delta effects_delivered 1)
    (expect-metric-delta effects_cancelled 0)
    (expect-pending-effects 0)
    (expect-text (test-id "log") "slow:spun 100000000 603|slow:timeout")
  )
)
