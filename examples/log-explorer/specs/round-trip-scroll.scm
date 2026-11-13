; Keep the viewer scope alive so the recorded scroll events retain their target.
(test "Log Explorer — round trip: scroll away and back"
  (setup
    (file "scroll.txt" "text/plain" "2026-11-11T08:00:00Z INFO api: line\n" 200))
  (steps
    (choose-files (label "Log file") "scroll.txt")
    (run-effect 1)
    (click (role button :name "Viewer"))
    (report-size (test-id "viewer-viewport") 800 400)
    (run-effect 2)
    (mark-metrics)
    (scroll (test-id "viewer-viewport") 1000 0)
    (run-effect 3)
    (expect-text (test-id "viewer-status") "Lines 51–70 of 200.")
    (scroll (test-id "viewer-viewport") 0 0)
    (run-effect 4)
    (expect-text (test-id "viewer-status") "Lines 1–20 of 200.")
    (expect-pending-effects 0)))
