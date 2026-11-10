(test "Log Explorer — typing past a search cancels it, and only the answer for the text in the box is shown"
  (setup
    (file "app.log" "text/x-log" "2026-11-11T08:00:00Z INFO api: order 12 paid\n2026-11-11T08:00:01Z INFO api: order 125 paid\n" 20))
  (steps
    (choose-files (label "Log file") "app.log")
    (click (role button :name "Search"))
    (fill (label "Text to find") "order 1")
    (mark-metrics)
    (fill (label "Text to find") "order 12")
    (fill (label "Text to find") "order 125")
    ; Each newer text cancels the search before it: one job is wanted.
    (expect-metric-delta effects_cancelled 2)
    (expect-pending-work "roc-signals.example/log-explorer/search" 1)
    (run-effect 5)
    (expect-text (test-id "search-status") "20 matching lines, page 1 of 1.")
    (expect-text (test-id "line-2") "2026-11-11T08:00:01Z INFO api: order 125 paid")
    (expect-absent (test-id "line-1"))
    (expect-pending-effects 0)
  )
)
