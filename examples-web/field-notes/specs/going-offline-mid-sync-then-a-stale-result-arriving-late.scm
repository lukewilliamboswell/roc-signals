(test "Field notes — going offline mid sync, then a stale result arriving late"
  (setup
    (manual-effects)
    ; One draft note is enough to exercise an offline/reconnect overlap.
    (local-storage "field-notes:notes" "n1|1|0|r7|Fence line check")
  )
  (steps
    ; going offline mid sync, then a stale result arriving late

    (click (role button :name "Queue note n1"))
    (expect-text (test-id "status-n1") "Syncing")
    (expect-pending-effects 1)
    (set-online offline)
    (expect-text (test-id "network") "Offline. Notes stay in the outbox until the connection returns.")
    (expect-text (test-id "status-n1") "Queued")
    (expect-text (test-id "syncing") "None")
    (expect-pending-effects 1)
    (set-online online)
    (expect-text (test-id "status-n1") "Syncing")
    (expect-pending-effects 2)
    ; Both effects survive; the first completion cannot publish over the newer generation.
    (mark-metrics)
    (stub-http "completed sync n1#r7" :url "/api/notes/sync" :status 200 :body "n1#r7")
    (run-effect 1)
    (expect-metric-delta patches_emitted 0)
    (expect-text (test-id "status-n1") "Syncing")
    (expect-pending-effects 1)
    (stub-http "completed sync n1#r7" :url "/api/notes/sync" :status 200 :body "n1#r7")
    (run-effect 2)
    (expect-text (test-id "status-n1") "Synced")
    (expect-text (test-id "synced-count") "1")
    (expect-visible (text "Outbox is empty"))
    (expect-pending-effects 0)
  )
)
