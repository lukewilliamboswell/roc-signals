(test "Field notes — returning to the page refreshes times"
  (setup
    (seed 7)
    (initial-online offline)
    (initial-time 0)
    (languages "en-AU"))
  (steps
    (fill (label "Note body") "Pump pressure")
    (click (role button :name "Save note"))
    (run-effect 1)
    (set-visibility hidden)
    (advance-time 180000)
    (set-visibility visible)
    (expect-text (test-id "captured-n-63cbe1e459320dd7") "Captured 00:00 · just now")
    (run-effect 2)
    (expect-text (test-id "captured-n-63cbe1e459320dd7") "Captured 00:00 · 3 min ago")))
