(test "State commands"
  (setup (manual-effects))
  (steps
    ; Interval commands and effect results update the same retained state model.

    (expect-visible (role heading :name "State commands"))
    (expect-text (test-id "count") "Count: 0")
    (expect-text (test-id "result") "waiting")
    (expect-pending-effects 1)
    (tick-interval 1000)
    (expect-text (test-id "count") "Count: 1")
    (mark-metrics)
    (tick-interval 1000)
    (expect-text (test-id "count") "Count: 2")
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
    (stub-http "state result" :url "/api/state-command" :status 200 :body "payload")
    (run-effect 1)
    (expect-text (test-id "result") "done:payload")
    (expect-pending-effects 0)
  )
)
