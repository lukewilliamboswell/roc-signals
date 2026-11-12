(test "Worker search — the latest query wins, and a superseded job is cancelled"
  (steps
    (fill (label "Search") "po")
    (expect-pending-work "test.roc-signals/search/filter" 1)
    (expect-text (test-id "status") "Searching…")
    (mark-metrics)
    ; A newer query supersedes the job in flight: it is cancelled, never run.
    (fill (label "Search") "roc")
    (expect-metric-delta effects_cancelled 1)
    (expect-metric-delta effects_issued 1)
    (expect-pending-work "test.roc-signals/search/filter" 1)
    (run-effect 2)
    (expect-text (test-id "status") "Found")
    (expect-text (test-id "results") "roc-signals, roc-fuzz, roc-automation, rocket")
    ; Case does not matter to the task, and no match is an answer too.
    (fill (label "Search") "POCKET")
    (run-effect 3)
    (expect-text (test-id "results") "pocket")
    (fill (label "Search") "xyz")
    (run-effect 4)
    (expect-text (test-id "results") "")
    (expect-text (test-id "status") "No matches")
    ; Clearing the query is a pure cancel.
    (fill (label "Search") "ab")
    (fill (label "Search") "")
    (expect-pending-effects 0)
    (expect-text (test-id "status") "")
  )
)
