(test "Field notes — without local storage"
  (setup
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
    (expect-visible (role region :name "Note s1"))
    (expect-value (label "Body s1") "Pump pressure log")
    (expect-text (test-id "storage-notice") "Local storage is unavailable, so nothing survives a reload")
    (expect-no-local-storage "field-notes:notes")
  )
)
