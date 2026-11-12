(test "Tasks — closing a panel stops its job, unless the task keeps it, whose answer reaches the page"
  (setup
    (file "notes.txt" "text/plain" "abcdef"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Panel"))
    (expect-pending-work "test.roc-signals/tasks/stopped" 1)
    (expect-pending-work "test.roc-signals/tasks/kept" 2)
    (mark-metrics)
    (click (role button :name "Panel"))
    (expect-absent (label "panel"))
    (expect-metric-delta effects_cancelled 1)
    (expect-metric-delta effects_reparented 2)
    (expect-pending-work "test.roc-signals/tasks/stopped" 0)
    (expect-pending-work "test.roc-signals/tasks/kept" 2)
    (run-effect 2)
    (expect-text (test-id "kept") "kept 6")
    ; The third job's reaction writes to a state the panel owned. The job
    ; still runs and answers, but that write is skipped: there is no state
    ; left to write to, and nothing else changes.
    (mark-metrics)
    (run-effect 3)
    (expect-metric-delta effects_delivered 1)
    (expect-metric-delta effects_skipped 1)
    (expect-absent (test-id "noted"))
    (expect-text (test-id "kept") "kept 6")
    (expect-pending-effects 0)
  )
)
