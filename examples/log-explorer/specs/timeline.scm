(test "Log Explorer — the timeline counts entries a minute, a search adds its matches, and a click opens the viewer at that time"
  (setup
    (file "app.txt" "text/plain" "2026-11-11T12:00:10Z INFO api: GET /orders/1 answered 200\n2026-11-11T12:00:40Z INFO api: GET /orders/2 answered 200\n2026-11-11T12:01:05Z ERROR checkout: POST /checkout answered 503\n    at Payments.charge (payments.roc:64)\n2026-11-11T12:01:30Z ERROR checkout: POST /checkout answered 503\n    at Payments.charge (payments.roc:64)\n2026-11-11T12:01:50Z WARN checkout: slow request: POST /checkout took 4100 ms\n2026-11-11T12:03:00Z INFO api: GET /orders/3 answered 200\n2026-11-11T12:61:00Z INFO api: a clock that runs past the hour\n" 10))
  (steps
    (choose-files (label "Log file") "app.txt")
    (run-effect 1)
    ; Timestamps are ordered as text, so the impossible 12:61 is the latest.
    (expect-text (test-id "overview") "90 lines, 70 entries, from 2026-11-11T12:00:10Z to 2026-11-11T12:61:00Z")
    (expect-attr (test-id "timeline") aria-label "Entries per minute by level")
    (expect-text (test-id "timeline-peak") "Most errors in a minute: 20 errors at 2026-11-11 12:01. Not on the timeline: 10 entries whose time is not a real one.")
    ; The chart reports a click as the point's time. The viewer opens at
    ; the first line of that minute, from the timeline the page has: one
    ; job, the viewer's own.
    (change (test-id "timeline") "2026-11-11 12:01")
    (report-size (test-id "viewer-viewport") 800 1000)
    (expect-pending-work "roc-signals.example/log-explorer/window" 1)
    (expect-scrolls 0)
    (run-effect 2)
    (expect-scrolls 1)
    (expect-scroll 1 (test-id "viewer-viewport") to)
    (expect-pending-effects 0)
    (expect-text (test-id "viewer-status") "Lines 3–52 of 90.")
    (expect-value (label "Go to line") "3")
    ; A minute with no entries opens at the next one that has some.
    (click (role button :name "Overview"))
    (change (test-id "timeline") "2026-11-11 12:02")
    (report-size (test-id "viewer-viewport") 800 1000)
    (run-effect 3)
    (expect-text (test-id "viewer-status") "Lines 8–57 of 90.")
    ; Plotly writes midnight as the date alone; it is before the log, which
    ; opens at its first line.
    (click (role button :name "Overview"))
    (change (test-id "timeline") "2026-11-11")
    (report-size (test-id "viewer-viewport") 800 1000)
    (run-effect 4)
    (expect-text (test-id "viewer-status") "Lines 1–50 of 90.")
    ; After the last entry, or not a time at all: nothing changes.
    (click (role button :name "Overview"))
    (change (test-id "timeline") "2026-11-11 13:00")
    (change (test-id "timeline") "not a time")
    (expect-pending-effects 0)
    (expect-attr (test-id "timeline") aria-label "Entries per minute by level")
    ; A listing with no text counts nothing over time; a search with text
    ; adds its matches, counted in their entry's minute.
    (click (role button :name "Search"))
    (run-effect 5)
    (expect-text (test-id "timeline-peak") "Most errors in a minute: 20 errors at 2026-11-11 12:01. Not on the timeline: 10 entries whose time is not a real one.")
    (fill (label "Text to find") "checkout")
    (run-effect 6)
    (expect-text (test-id "search-status") "30 matching lines, page 1 of 2.")
    (expect-attr (test-id "timeline") aria-label "Entries per minute by level, and the search's matches")
    (expect-text (test-id "timeline-peak") "Most matches in a minute: 30 matches at 2026-11-11 12:01. Not on the timeline: 10 entries whose time is not a real one.")
    ; A click on the search's chart opens the viewer too.
    (change (test-id "timeline") "2026-11-11 12:03")
    (report-size (test-id "viewer-viewport") 800 1000)
    (run-effect 7)
    (expect-text (test-id "viewer-status") "Lines 8–57 of 90.")
    (expect-pending-effects 0)
  )
)
