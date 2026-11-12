(test "Field notes — a note saved where a synced note was deleted is sent, not taken for it"
  (setup
    ; The storage an earlier session left: a queued note that session
    ; captured and edited once, "s1" at revision "s1:1".

    (local-storage "field-notes:notes" "s1|0|1|s1:1|Pump pressure log")
  )
  (steps
    (expect-text (test-id "status-s1") "Syncing")
    (stub-http "sync s1#s1:1" :url "/api/notes/sync" :status 200 :body "s1#s1:1")
    (run-effect 1)
    (expect-text (test-id "status-s1") "Synced")
    (click (role button :name "Delete note s1"))
    (expect-absent (role region :name "Note s1"))

    ; A session numbers its notes from one, so the next note saved is "s1"
    ; again, in the slot the deleted note left, and one edit gives it the
    ; revision that note synced at.
    (fill (label "Note body") "Tank level 42")
    (click (role button :name "Save note"))
    (expect-text (test-id "status-s1") "Draft")
    (fill (label "Body s1") "Tank level 43")
    (click (role button :name "Queue note s1"))

    ; The lane forgot what it settled when its note was deleted, so this
    ; note is sent.
    (expect-text (test-id "status-s1") "Syncing")
    (expect-pending-effects 1)
    (stub-http "sync s1#s1:1" :url "/api/notes/sync" :status 200 :body "s1#s1:1")
    (run-effect 2)
    (expect-text (test-id "status-s1") "Synced")
    (expect-pending-effects 0)
    (expect-local-storage "field-notes:notes" "s1|0|1|s1:1|Tank level 43")
  )
)
