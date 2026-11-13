(test "Log Explorer — scrolling back supersedes the pending window"
  (setup
    (file "app.txt" "text/plain" "2026-11-11T08:00:00Z INFO api: line\n" 200))
  (steps
    (choose-files (label "Log file") "app.txt")
    (run-effect 1)
    (click (role button :name "Viewer"))
    (report-size (test-id "viewer-viewport") 800 400)
    (run-effect 2)
    (expect-text (test-id "viewer-status") "Lines 1–20 of 200.")
    (expect-scrolls 1)
    (mark-metrics)
    (scroll (test-id "viewer-viewport") 1000 0)
    (scroll (test-id "viewer-viewport") 200 0)
    (expect-metric-delta effects_cancelled 1)
    (expect-pending-work "roc-signals.example/log-explorer/window" 1)
    ; The cancelled occurrence cannot answer; only the newer job remains.
    (run-effect 4)
    (expect-text (test-id "viewer-status") "Lines 11–30 of 200.")
    (expect-text (test-id "line-11") "2026-11-11T08:00:00Z INFO api: line")
    (expect-absent (test-id "line-1"))
    (expect-pending-effects 0)
    (expect-scrolls 1)))
