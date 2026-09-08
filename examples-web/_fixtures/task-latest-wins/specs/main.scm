(test "Task latest wins"
  (steps
    ; Latest task request wins; stale completions are ignored.

    (expect-visible (role heading :name "Task latest wins"))
    (expect-text (text "Task status: loading") "Task status: loading")
    (expect-pending-task "lookup" 1)
    (expect-canceled-task "lookup" 0)
    (click (role button :name "Refresh"))
    (expect-pending-task "lookup" 1)
    (expect-canceled-task "lookup" 1)
    (expect-text (text "Task status: loading") "Task status: loading")
    (mark-metrics)
    (resolve-stale-task "lookup" "stale result")
    (expect-metric-delta stale_task_results_ignored 1)
    (expect-pending-task "lookup" 1)
    (expect-text (text "Task status: loading") "Task status: loading")
    (resolve-task "lookup" "fresh result")
    (expect-pending-task "lookup" 0)
    (expect-text (text "Task status: done fresh result") "Task status: done fresh result")

    ; Warm the completed -> loading -> completed path once. Its first pass can
    ; grow bounded HostValue-registry and allocation-ledger capacity even when
    ; all application-owned values are released.
    (click (role button :name "Refresh"))
    (resolve-task "lookup" "other result")
    (expect-text (text "Task status: done other result") "Task status: done other result")

    ; Repeating the same-sized transition must now release the previous task
    ; payload and remain at the established retained allocation plateau.
    (mark-metrics)
    (click (role button :name "Refresh"))
    (resolve-task "lookup" "third result")
    (expect-text (text "Task status: done third result") "Task status: done third result")
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
  )
)
