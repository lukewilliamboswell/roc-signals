(test "Field notes — reorder: promoting a note changes the drain order"
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
    (click (role button :name "Queue note n-63cbe1e459320dd7"))
    (click (role button :name "Queue note n-044c3cd7f43c661c"))

    ; reorder: promoting a note changes the drain order

    (mark-metrics)
    (click (role button :name "Promote note n-044c3cd7f43c661c"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 4)
    (click (role button :name "Promote note n0"))
    (expect-text (test-id "status-n0") "Queued")
    (expect-text (test-id "status-n-044c3cd7f43c661c") "Queued")
  )
)
