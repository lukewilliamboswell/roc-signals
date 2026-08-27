(test "State commands"
  (steps
    ; Commands emitted by interval and task sources can update retained state.

    (expect-visible (role heading :name "State commands"))
    (expect-text (test-id "count") "Count: 0")
    (expect-text (test-id "result") "waiting")
    (expect-pending-task "state-command-task" 1)
    (tick-interval 1000)
    (expect-text (test-id "count") "Count: 1")
    (mark-metrics)
    (tick-interval 1000)
    (expect-text (test-id "count") "Count: 2")
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
    (resolve-task "state-command-task" "payload")
    (expect-text (test-id "result") "done:payload")
    (expect-pending-task "state-command-task" 0)
  )
)
