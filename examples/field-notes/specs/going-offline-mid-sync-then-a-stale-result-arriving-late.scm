(test "Field notes — going offline mid sync, then a stale result arriving late"
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
    (mark-metrics)
    (fill (label "Body n0") "Generator hours 128")
    (resolve-task "note-sync" "n0#n0:1")

    ; going offline mid sync, then a stale result arriving late

    (click (role button :name "Queue note n1"))
    (expect-text (test-id "status-n1") "Note n1 status: syncing")
    (expect-pending-task "note-sync" 1)
    (expect-canceled-task "note-sync" 0)
    (set-online offline)
    (expect-text (test-id "network") "Network: offline")
    (expect-text (test-id "status-n1") "Note n1 status: queued")
    (expect-text (test-id "syncing") "Syncing: none")
    (expect-pending-task "note-sync" 1)
    (set-online online)
    (expect-text (test-id "status-n1") "Note n1 status: syncing")
    (expect-pending-task "note-sync" 1)
    (expect-canceled-task "note-sync" 1)
    ; The request abandoned at the offline edge settles after the newer one started.
    (mark-metrics)
    (resolve-stale-task "note-sync" "n1#r7")
    (expect-metric-delta stale_task_results_ignored 1)
    (expect-text (test-id "status-n1") "Note n1 status: syncing")
    (expect-pending-task "note-sync" 1)
    (resolve-task "note-sync" "n1#r7")
    (expect-text (test-id "status-n1") "Note n1 status: synced")
    (expect-text (test-id "synced-count") "Synced: 4")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-task "note-sync" 0)
  )
)
