(test "Field notes — without local storage"
  (setup
    (seed 7)
    ; A browser with site data disabled: every access to local storage throws.
    ; The board starts empty, still captures notes, and says plainly that
    ; nothing will survive a reload.
    (initial-online offline)
    (local-storage-unavailable)
  )
  (steps
    (expect-text (test-id "storage-notice") "Local storage is unavailable, so nothing survives a reload")
    (expect-text (test-id "capacity") "0 of 4")
    (fill (label "Note body") "Pump pressure log")
    (click (role button :name "Save note"))
    (run-effect 1)
    (expect-visible (role region :name "Note n-63cbe1e459320dd7"))
    (expect-value (label "Body n-63cbe1e459320dd7") "Pump pressure log")
    (expect-text (test-id "storage-notice") "Local storage is unavailable, so nothing survives a reload")
    (expect-no-local-storage "field-notes:notes")
  )
)
