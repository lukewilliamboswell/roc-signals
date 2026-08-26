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
  )
)
