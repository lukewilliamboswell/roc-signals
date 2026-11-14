(test "Field notes — a clock that jumps back"
  (setup
    (seed 7)
    (initial-online offline)
    (initial-time 180000)
    (languages "en-AU"))
  (steps
    (fill (label "Note body") "Pump pressure")
    (click (role button :name "Save note"))
    (run-effect 1)
    (advance-time 180000)
    (tick-interval 30000)
    (expect-text (test-id "captured-n-63cbe1e459320dd7") "Captured 00:03 · 3 min ago")
    (set-time -60000)
    (tick-interval 30000)
    (expect-text (test-id "captured-n-63cbe1e459320dd7") "Captured 00:03 · just now")
    (expect-attr (test-id "captured-n-63cbe1e459320dd7") datetime "1970-01-01T00:03:00Z")))
