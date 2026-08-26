(test "Field notes — retrying the failed note"
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
    (click (role button :name "Queue note s1"))
    (click (role button :name "Queue note s2"))
    (mark-metrics)
    (click (role button :name "Promote note s2"))
    (click (role button :name "Promote note n0"))
    (set-online online)
    (resolve-task "note-sync" "n0#r7")
    (reject-task "note-sync" "s2#r0")
    (resolve-task "note-sync" "s1#r0")

    ; retrying the failed note

    (expect-disabled (role button :name "Retry note s2") false)
    (click (role button :name "Retry note s2"))
    (expect-text (test-id "status-s2") "Syncing")
    (expect-pending-task "note-sync" 1)
    (resolve-task "note-sync" "s2#s2:1")
    (expect-text (test-id "status-s2") "Synced")
    (expect-text (test-id "synced-count") "3")
    (expect-text (test-id "failed-count") "0")
    (expect-text (test-id "outbox-count") "0")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-task "note-sync" 0)
  )
)
