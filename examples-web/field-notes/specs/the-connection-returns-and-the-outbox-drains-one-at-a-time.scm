(test "Field notes — the connection returns and the outbox drains one at a time"
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

    ; the connection returns and the outbox drains one at a time

    (set-online online)
    (expect-attr (role region :name "Sync status") data-network "online")
    (expect-text (test-id "network") "Online. The outbox drains one note at a time.")
    (expect-text (test-id "syncing") "n0")
    (expect-attr (role region :name "Note n0") data-status "syncing")
    (expect-attr (role region :name "Note s2") data-status "queued")
    (expect-attr (role region :name "Note s1") data-status "queued")
    (expect-attr (role region :name "Note n1") data-status "draft")
    (expect-pending-task "note-sync" 1)
    (resolve-task "note-sync" "n0#r7")
    (expect-text (test-id "status-n0") "Synced")
    (expect-text (test-id "synced-count") "1")
    (expect-text (test-id "syncing") "s2")
    (expect-text (test-id "outbox-count") "2")
    (expect-pending-task "note-sync" 1)
    ; A failure rolls that note back to failed; its siblings are untouched and the
    ; queue keeps draining past it.
    (reject-task "note-sync" "s2#r0")
    (expect-text (test-id "status-s2") "Failed")
    (expect-attr (role region :name "Note s2") data-status "failed")
    (expect-text (test-id "failed-count") "1")
    (expect-text (test-id "status-n0") "Synced")
    (expect-text (test-id "syncing") "s1")
    (expect-pending-task "note-sync" 1)
    (resolve-task "note-sync" "s1#r0")
    (expect-text (test-id "status-s1") "Synced")
    (expect-text (test-id "synced-count") "2")
    (expect-text (test-id "failed-count") "1")
    (expect-text (test-id "syncing") "None")
    (expect-text (test-id "outbox-count") "1")
    (expect-pending-task "note-sync" 0)
  )
)
