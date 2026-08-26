(test "Field notes — initial mount"
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
    ; initial mount

    (expect-visible (role heading :name "Field Notes"))
    (expect-text (test-id "storage-notice") "Storage notice: notes are restored on reload")
    (expect-visible (role region :name "Capture"))
    (expect-visible (role heading :name "New note"))
    (expect-value (label "Note body") "")
    (expect-disabled (role button :name "Save note") true)
    (expect-visible (role region :name "Sync status"))
    (expect-attr (role region :name "Sync status") data-network "offline")
    (expect-text (test-id "network") "Network: offline")
    (expect-text (test-id "auto-sync") "Auto sync: on")
    (expect-text (test-id "outbox-count") "Outbox: 1")
    (expect-text (test-id "syncing") "Syncing: none")
    (expect-text (test-id "failed-count") "Failed: 0")
    (expect-text (test-id "synced-count") "Synced: 0")
    (expect-text (test-id "capacity") "Capacity: 2 of 4")
    (expect-checked (label "Sync automatically") true)
    (expect-checked (label "Hide synced notes") false)
    (expect-visible (role region :name "Outbox"))
    (expect-text (test-id "outbox-detail") "Outbox holds 1 notes")
    (expect-visible (role region :name "Notes"))
    (expect-visible (role region :name "Note n0"))
    (expect-value (label "Body n0") "Generator hours")
    (expect-text (test-id "status-n0") "Note n0 status: queued")
    (expect-attr (role region :name "Note n0") data-status "queued")
    (expect-disabled (role button :name "Queue note n0") true)
    (expect-disabled (role button :name "Retry note n0") true)
    (expect-visible (role region :name "Note n1"))
    (expect-value (label "Body n1") "Fence line check")
    (expect-text (test-id "status-n1") "Note n1 status: draft")
    (expect-attr (role region :name "Note n1") data-status "draft")
    (expect-disabled (role button :name "Queue note n1") false)
    (expect-disabled (role button :name "Retry note n1") true)
    (expect-absent (role region :name "Note s1"))
    ; Offline means nothing is started even though a restored note is queued.
    (expect-pending-task "note-sync" 0)
    (expect-canceled-task "note-sync" 0)
  )
)
