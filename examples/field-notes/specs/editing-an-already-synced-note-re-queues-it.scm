(test "Field notes — editing an already synced note re queues it"
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
    (mark-metrics)
    (click (role button :name "Promote note n-044c3cd7f43c661c"))
    (click (role button :name "Promote note n0"))
    (set-online online)
    (stub-http "sync n0#r7" :url "/api/notes/sync" :status 200 :body "n0#r7")
    (run-effect 3)
    (stub-http "failed sync n-044c3cd7f43c661c#r0" :url "/api/notes/sync" :status 503 :body "temporarily unavailable")
    (run-effect 4)
    (stub-http "sync n-63cbe1e459320dd7#r0" :url "/api/notes/sync" :status 200 :body "n-63cbe1e459320dd7#r0")
    (run-effect 5)
    (click (role button :name "Retry note n-044c3cd7f43c661c"))
    (stub-http "sync n-044c3cd7f43c661c#n-044c3cd7f43c661c:1" :url "/api/notes/sync" :status 200 :body "n-044c3cd7f43c661c#n-044c3cd7f43c661c:1")
    (run-effect 6)

    ; editing an already synced note re queues it
    ; An edit gives the note its next revision, so a token its lane has not
    ; settled: the note re-enters the outbox and syncs again.

    (mark-metrics)
    (fill (label "Body n0") "Generator hours 128")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 4)
    (expect-text (test-id "status-n0") "Syncing")
    (expect-text (test-id "outbox-count") "1")
    (expect-pending-effects 1)
    ; Editing one row does not disturb its siblings.
    (expect-value (label "Body n-63cbe1e459320dd7") "Pump pressure log")
    (expect-text (test-id "status-n-63cbe1e459320dd7") "Synced")
    (expect-value (label "Body n-044c3cd7f43c661c") "Tank level 42")
    (expect-text (test-id "status-n-044c3cd7f43c661c") "Synced")
    (expect-value (label "Body n1") "Fence line check")
    (expect-text (test-id "status-n1") "Draft")
    (stub-http "sync n0#n0:1" :url "/api/notes/sync" :status 200 :body "n0#n0:1")
    (run-effect 7)
    (expect-text (test-id "status-n0") "Synced")
    (expect-value (label "Body n0") "Generator hours 128")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-effects 0)
  )
)
