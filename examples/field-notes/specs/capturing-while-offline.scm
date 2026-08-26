(test "Field notes — capturing while offline"
  (setup
    ; Field Notes: offline capture, outbox drain, rollback, and restore.
    ;
    ; Storage format is "id|slot|queued|rev|body" per note, notes joined by ";".
    ; Notes captured in this session get session ids ("s<n>"). Every operation is
    ; idempotent, so replaying the log over the value it just persisted is stable.

    (initial-online offline)
    (local-storage "field-notes:notes" "n0|0|1|r7|Generator hours;n1|1|0|r7|Fence line check")
  )
  (steps
    ; capturing while offline

    (fill (label "Note body") "Pump pressure log")
    (expect-value (label "Note body") "Pump pressure log")
    (expect-disabled (role button :name "Save note") false)
    (click (role button :name "Save note"))
    (expect-value (label "Note body") "")
    (expect-disabled (role button :name "Save note") true)
    (expect-visible (role region :name "Note s1"))
    (expect-value (label "Body s1") "Pump pressure log")
    (expect-text (test-id "status-s1") "Note s1 status: draft")
    (expect-text (test-id "capacity") "Capacity: 3 of 4")
    (expect-text (test-id "outbox-count") "Outbox: 1")
    (expect-pending-task "note-sync" 0)
    ; Whitespace-only drafts cannot be saved.
    (fill (label "Note body") "   ")
    (expect-disabled (role button :name "Save note") true)
    (fill (label "Note body") "Tank level 42")
    (click (role button :name "Save note"))
    (expect-visible (role region :name "Note s2"))
    (expect-value (label "Body s2") "Tank level 42")
    (expect-text (test-id "capacity") "Capacity: full")
    ; Boundary: the outbox holds four notes, so a fifth capture is refused.
    (fill (label "Note body") "Overflow note")
    (expect-disabled (role button :name "Save note") true)
    (fill (label "Note body") "")
  )
)
