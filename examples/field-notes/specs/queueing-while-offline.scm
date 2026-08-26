(test "Field notes — queueing while offline"
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
    ; Given the state established by earlier scenarios
    (fill (label "Note body") "Pump pressure log")
    (click (role button :name "Save note"))
    (fill (label "Note body") "   ")
    (fill (label "Note body") "Tank level 42")
    (click (role button :name "Save note"))
    (fill (label "Note body") "Overflow note")
    (fill (label "Note body") "")

    ; queueing while offline

    (click (role button :name "Queue note s1"))
    (expect-text (test-id "status-s1") "Note s1 status: queued")
    (expect-disabled (role button :name "Queue note s1") true)
    (click (role button :name "Queue note s2"))
    (expect-text (test-id "status-s2") "Note s2 status: queued")
    (expect-text (test-id "outbox-count") "Outbox: 3")
    (expect-text (test-id "outbox-detail") "Outbox holds 3 notes")
    (expect-text (test-id "syncing") "Syncing: none")
    (expect-pending-task "note-sync" 0)
  )
)
