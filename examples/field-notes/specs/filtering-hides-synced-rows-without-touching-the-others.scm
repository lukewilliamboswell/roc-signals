(test "Field notes — filtering hides synced rows without touching the others"
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
    (click (role button :name "Queue note n1"))
    (set-online offline)
    (set-online online)
    (mark-metrics)
    (resolve-stale-task "note-sync" "n1#r7")
    (resolve-task "note-sync" "n1#r7")
    (uncheck (label "Sync automatically"))
    (click (role button :name "Delete note s2"))
    (fill (label "Note body") "Radio check")
    (click (role button :name "Save note"))
    (click (role button :name "Queue note s3"))
    (click (role button :name "Delete note s3"))
    (check (label "Sync automatically"))

    ; filtering hides synced rows without touching the others

    (mark-metrics)
    (check (label "Hide synced notes"))
    (expect-metric-delta rows_removed 3)
    (expect-metric-delta rows_created 0)
    (expect-absent (role region :name "Note n0"))
    (expect-absent (role region :name "Note n1"))
    (expect-absent (role region :name "Note s1"))
    (expect-text (test-id "synced-count") "Synced: 3")
    (uncheck (label "Hide synced notes"))
    (expect-visible (role region :name "Note n0"))
    (expect-visible (role region :name "Note n1"))
    (expect-visible (role region :name "Note s1"))
    (expect-value (label "Body n0") "Generator hours 128")
  )
)
