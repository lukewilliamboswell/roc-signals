(test "Field notes — editing an already synced note re queues it"
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
    (click (role button :name "Retry note s2"))
    (resolve-task "note-sync" "s2#s2:1")

    ; editing an already synced note re queues it
    ; Documented behaviour: an edit bumps the note's attempt, which invalidates the
    ; lane's settled token, so the note re-enters the outbox and syncs again.

    (mark-metrics)
    (fill (label "Body n0") "Generator hours 128")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 4)
    (expect-text (test-id "status-n0") "Note n0 status: syncing")
    (expect-text (test-id "outbox-count") "Outbox: 1")
    (expect-pending-task "note-sync" 1)
    ; Editing one row does not disturb its siblings.
    (expect-value (label "Body s1") "Pump pressure log")
    (expect-text (test-id "status-s1") "Note s1 status: synced")
    (expect-value (label "Body s2") "Tank level 42")
    (expect-text (test-id "status-s2") "Note s2 status: synced")
    (expect-value (label "Body n1") "Fence line check")
    (expect-text (test-id "status-n1") "Note n1 status: draft")
    (resolve-task "note-sync" "n0#n0:1")
    (expect-text (test-id "status-n0") "Note n0 status: synced")
    (expect-value (label "Body n0") "Generator hours 128")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-task "note-sync" 0)
  )
)
