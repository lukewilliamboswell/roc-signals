(test "Field notes — persistence"
  (setup
    (manual-effects)
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
    (stub-http "completed sync n0#r7" :url "/api/notes/sync" :status 200 :body "n0#r7")
    (run-effect 1)
    (stub-http "failed sync s2#r0" :url "/api/notes/sync" :status 503 :body "temporarily unavailable")
    (run-effect 2)
    (stub-http "completed sync s1#r0" :url "/api/notes/sync" :status 200 :body "s1#r0")
    (run-effect 3)
    (click (role button :name "Retry note s2"))
    (stub-http "completed sync s2#s2:1" :url "/api/notes/sync" :status 200 :body "s2#s2:1")
    (run-effect 4)
    (mark-metrics)
    (fill (label "Body n0") "Generator hours 128")
    (stub-http "completed sync n0#n0:1" :url "/api/notes/sync" :status 200 :body "n0#n0:1")
    (run-effect 5)
    (click (role button :name "Queue note n1"))
    (set-online offline)
    (set-online online)
    (mark-metrics)
    (stub-http "completed sync n1#r7" :url "/api/notes/sync" :status 200 :body "n1#r7")
    (run-effect 6)
    (stub-http "completed sync n1#r7" :url "/api/notes/sync" :status 200 :body "n1#r7")
    (run-effect 7)
    (uncheck (label "Sync automatically"))
    (click (role button :name "Delete note s2"))
    (fill (label "Note body") "Radio check")
    (click (role button :name "Save note"))
    (click (role button :name "Queue note s3"))
    (click (role button :name "Delete note s3"))
    (check (label "Sync automatically"))
    (mark-metrics)
    (check (label "Hide synced notes"))
    (uncheck (label "Hide synced notes"))

    ; persistence

    (expect-local-storage "field-notes:notes" "n0|0|1|n0:1|Generator hours 128;n1|1|1|r7|Fence line check;s1|2|1|r0|Pump pressure log")
  )
)
