; A round trip back to the search tab it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics`, answering each job as this run
; answered it, and requires them to leave nothing allocated. The log is
; chosen, its overview answered and the search tab opened before the mark.
; The soak replays each event to the element it was recorded on, so the
; cycle stays in the search tab, whose box, buttons and chart were made
; before the mark: leaving the tab would make them again under other ids.
(test "Log Explorer — round trip: a search drawn on the timeline, paged, and cleared"
  (setup
    (file "app.log" "text/x-log" "2026-11-11T12:00:10Z INFO api: GET /orders/1 answered 200\n2026-11-11T12:01:05Z ERROR checkout: POST /checkout answered 503\n    at Payments.charge (payments.roc:64)\n2026-11-11T12:03:00Z WARN checkout: slow request: POST /checkout took 4100 ms\n" 20))
  (steps
    (choose-files (label "Log file") "app.log")
    (run-effect 1)
    (click (role button :name "Search"))
    (run-effect 2)
    (expect-text (test-id "timeline-peak") "Most errors in a minute: 20 errors at 2026-11-11 12:01.")
    (mark-metrics)
    (fill (label "Text to find") "checkout")
    (run-effect 3)
    (expect-text (test-id "search-status") "40 matching lines, page 1 of 2.")
    (expect-text (test-id "timeline-peak") "Most matches in a minute: 20 matches at 2026-11-11 12:01.")
    (click (role button :name "Next page"))
    (run-effect 4)
    (expect-text (test-id "search-status") "40 matching lines, page 2 of 2.")
    (click (role button :name "Previous page"))
    (run-effect 5)
    (fill (label "Text to find") "")
    (run-effect 6)
    (expect-text (test-id "search-status") "80 matching lines, page 1 of 4.")
    (expect-text (test-id "timeline-peak") "Most errors in a minute: 20 errors at 2026-11-11 12:01.")
    (expect-pending-effects 0)
  )
)
