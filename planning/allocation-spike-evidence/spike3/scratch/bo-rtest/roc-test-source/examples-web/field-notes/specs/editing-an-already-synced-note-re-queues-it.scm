(test "Field notes — editing an already synced note re queues it"
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
    (stub-http "sync n0#r7" :url "/api/notes/sync" :status 200 :body "n0#r7")
    (run-effect 1)
    (stub-http "failed sync s2#r0" :url "/api/notes/sync" :status 503 :body "temporarily unavailable")
    (run-effect 2)
    (stub-http "sync s1#r0" :url "/api/notes/sync" :status 200 :body "s1#r0")
    (run-effect 3)
    (click (role button :name "Retry note s2"))
    (stub-http "sync s2#s2:1" :url "/api/notes/sync" :status 200 :body "s2#s2:1")
    (run-effect 4)

    ; editing an already synced note re queues it
    ; Documented behaviour: an edit bumps the note's attempt, which invalidates the
    ; lane's settled token, so the note re-enters the outbox and syncs again.

    (mark-metrics)
    (fill (label "Body n0") "Generator hours 128")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 4)
    (expect-text (test-id "status-n0") "Syncing")
    (expect-text (test-id "outbox-count") "1")
    (expect-pending-effects 1)
    ; Editing one row does not disturb its siblings.
    (expect-value (label "Body s1") "Pump pressure log")
    (expect-text (test-id "status-s1") "Synced")
    (expect-value (label "Body s2") "Tank level 42")
    (expect-text (test-id "status-s2") "Synced")
    (expect-value (label "Body n1") "Fence line check")
    (expect-text (test-id "status-n1") "Draft")
    (stub-http "sync n0#n0:1" :url "/api/notes/sync" :status 200 :body "n0#n0:1")
    (run-effect 5)
    (expect-text (test-id "status-n0") "Synced")
    (expect-value (label "Body n0") "Generator hours 128")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-effects 0)
  )
)
