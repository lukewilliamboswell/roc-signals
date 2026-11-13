(test "Field notes — capture time in the users zone"
  (setup
    (seed 7)
    (initial-online offline)
    (initial-time "2026-11-13T00:40:00Z")
    (languages "en-AU")
    (time-zone "Australia/Brisbane" 600))
  (steps
    (fill (label "Note body") "Pump pressure")
    (click (role button :name "Save note"))
    (expect-text (test-id "captured-n-63cbe1e459320dd7") "just now")
    (run-effect 1)
    (expect-text (test-id "captured-n-63cbe1e459320dd7") "Captured 10:40 · just now")
    (expect-attr (test-id "captured-n-63cbe1e459320dd7") datetime "2026-11-13T00:40:00Z")
    (expect-local-storage "field-notes:notes" "n-63cbe1e459320dd7|0|0|r0|1794530400000|Pump pressure")))
