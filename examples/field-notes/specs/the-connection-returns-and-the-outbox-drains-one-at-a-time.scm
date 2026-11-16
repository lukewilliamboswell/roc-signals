(test "Field notes — the connection returns and the outbox drains one at a time"
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

    ; the connection returns and the outbox drains one at a time

    (set-online online)
    (expect-attr (role region :name "Sync status") data-network "online")
    (expect-text (test-id "network") "Online. The outbox drains one note at a time.")
    (expect-text (test-id "syncing") "n0")
    (expect-attr (role region :name "Note n0") data-status "syncing")
    (expect-attr (role region :name "Note n-044c3cd7f43c661c") data-status "queued")
    (expect-attr (role region :name "Note n-63cbe1e459320dd7") data-status "queued")
    (expect-attr (role region :name "Note n1") data-status "draft")
    (expect-pending-effects 1)
    (stub-http "sync n0#r7" :url "/api/notes/sync" :status 200 :body "n0#r7")
    (run-effect 3)
    (expect-text (test-id "status-n0") "Synced")
    (expect-text (test-id "synced-count") "1")
    (expect-text (test-id "syncing") "n-044c3cd7f43c661c")
    (expect-text (test-id "outbox-count") "2")
    (expect-pending-effects 1)
    ; A failure rolls that note back to failed; its siblings are untouched and the
    ; queue keeps draining past it.
    (stub-http "failed sync n-044c3cd7f43c661c#r0" :url "/api/notes/sync" :status 503 :body "temporarily unavailable")
    (run-effect 4)
    (expect-text (test-id "status-n-044c3cd7f43c661c") "Failed")
    (expect-attr (role region :name "Note n-044c3cd7f43c661c") data-status "failed")
    (expect-text (test-id "failed-count") "1")
    (expect-text (test-id "status-n0") "Synced")
    (expect-text (test-id "syncing") "n-63cbe1e459320dd7")
    (expect-pending-effects 1)
    (stub-http "sync n-63cbe1e459320dd7#r0" :url "/api/notes/sync" :status 200 :body "n-63cbe1e459320dd7#r0")
    (run-effect 5)
    (expect-text (test-id "status-n-63cbe1e459320dd7") "Synced")
    (expect-text (test-id "synced-count") "2")
    (expect-text (test-id "failed-count") "1")
    (expect-text (test-id "syncing") "None")
    (expect-text (test-id "outbox-count") "1")
    (expect-pending-effects 0)
  )
)
