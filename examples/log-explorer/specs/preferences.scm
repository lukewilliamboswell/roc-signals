(test "Log Explorer — the timeline starts with its declared preference and follows media reports"
  (setup
    (initial-media "(prefers-color-scheme: dark)" true)
    (file "entry.txt" "text/plain" "2026-11-11T12:00:00Z INFO sample: a line\n"))
  (steps
    (expect-media-subscriptions "(prefers-color-scheme: dark)" 1)
    ; The background is chosen before any job answers or media changes.
    (expect-attr (test-id "timeline") data-background "rgb(15,23,42)")
    (choose-files (label "Log file") "entry.txt")
    (run-effect 1)
    (expect-attr (test-id "timeline") data-background "rgb(15,23,42)")
    (expect-updates (test-id "timeline") 3)
    (set-media "(prefers-color-scheme: dark)" false)
    (expect-attr (test-id "timeline") data-background "rgb(255,255,255)")
    ; Both the authored background and Plume figure change, without a job.
    (expect-updates (test-id "timeline") 5)
    (expect-pending-effects 0)
    (set-media "(prefers-color-scheme: dark)" false)
    (expect-updates (test-id "timeline") 5)
    (set-media "(prefers-color-scheme: dark)" true)
    (expect-attr (test-id "timeline") data-background "rgb(15,23,42)")
    (expect-media-subscriptions "(prefers-color-scheme: dark)" 1)))
