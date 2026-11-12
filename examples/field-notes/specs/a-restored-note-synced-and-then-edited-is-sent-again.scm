(test "Field notes — a restored note that syncs and is then edited is sent again"
  (setup
    ; The storage an earlier session left: a queued note that session
    ; edited once, which gave it the revision "n0:1".

    (local-storage "field-notes:notes" "n0|0|1|n0:1|Generator hours 128")
  )
  (steps
    ; The restored note heads the outbox and is sent as it was stored.
    (expect-text (test-id "status-n0") "Syncing")
    (stub-http "sync n0#n0:1" :url "/api/notes/sync" :status 200 :body "n0#n0:1")
    (run-effect 1)
    (expect-text (test-id "status-n0") "Synced")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-effects 0)

    ; An edit gives the note the revision after the one it was restored at,
    ; which its lane has not settled, so the edit is queued and sent.
    (fill (label "Body n0") "Generator hours 130")
    (expect-text (test-id "status-n0") "Syncing")
    (expect-text (test-id "outbox-count") "1")
    (expect-pending-effects 1)
    (stub-http "sync n0#n0:2" :url "/api/notes/sync" :status 200 :body "n0#n0:2")
    (run-effect 2)
    (expect-text (test-id "status-n0") "Synced")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-effects 0)
    (expect-local-storage "field-notes:notes" "n0|0|1|n0:2|Generator hours 130")
  )
)
