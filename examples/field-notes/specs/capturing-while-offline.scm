(test "Field notes — capturing while offline"
  (setup
    (seed 7)
    ; Field Notes: offline capture, outbox drain, rollback, and restore.
    ;
    ; These five-field fixtures exercise restoration of notes captured before
    ; timestamps were stored. New notes use the document seed and sampled time.

    (initial-online offline)
    (local-storage "field-notes:notes" "n0|0|1|r7|Generator hours;n1|1|0|r7|Fence line check")
  )
  (steps
    ; capturing while offline

    (fill (label "Note body") "Pump pressure log")
    (expect-value (label "Note body") "Pump pressure log")
    (expect-disabled (role button :name "Save note") false)
    (click (role button :name "Save note"))
    (run-effect 1)
    (expect-value (label "Note body") "")
    (expect-disabled (role button :name "Save note") true)
    (expect-visible (role region :name "Note n-63cbe1e459320dd7"))
    (expect-value (label "Body n-63cbe1e459320dd7") "Pump pressure log")
    (expect-text (test-id "status-n-63cbe1e459320dd7") "Draft")
    (expect-text (test-id "capacity") "3 of 4")
    (expect-text (test-id "outbox-count") "1")
    (expect-pending-effects 0)
    ; Whitespace-only drafts cannot be saved.
    (fill (label "Note body") "   ")
    (expect-disabled (role button :name "Save note") true)
    (fill (label "Note body") "Tank level 42")
    (click (role button :name "Save note"))
    (run-effect 2)
    (expect-visible (role region :name "Note n-044c3cd7f43c661c"))
    (expect-value (label "Body n-044c3cd7f43c661c") "Tank level 42")
    (expect-text (test-id "capacity") "Full")
    ; Boundary: the outbox holds four notes, so a fifth capture is refused.
    (fill (label "Note body") "Overflow note")
    (expect-disabled (role button :name "Save note") true)
    (fill (label "Note body") "")
  )
)
