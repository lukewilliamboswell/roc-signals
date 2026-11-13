(test "Field notes — queueing while offline"
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
    ; Bring the page to the state this spec starts from.
    (fill (label "Note body") "Pump pressure log")
    (click (role button :name "Save note"))
    (run-effect 1)
    (fill (label "Note body") "   ")
    (fill (label "Note body") "Tank level 42")
    (click (role button :name "Save note"))
    (run-effect 2)
    (fill (label "Note body") "Overflow note")
    (fill (label "Note body") "")

    ; queueing while offline

    (click (role button :name "Queue note n-63cbe1e459320dd7"))
    (expect-text (test-id "status-n-63cbe1e459320dd7") "Queued")
    (expect-disabled (role button :name "Queue note n-63cbe1e459320dd7") true)
    (click (role button :name "Queue note n-044c3cd7f43c661c"))
    (expect-text (test-id "status-n-044c3cd7f43c661c") "Queued")
    (expect-text (test-id "outbox-count") "3")
    (expect-text (test-id "outbox-detail") "3 notes waiting to sync")
    (expect-text (test-id "syncing") "None")
    (expect-pending-effects 0)
  )
)
