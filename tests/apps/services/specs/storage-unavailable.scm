(test "Services — a browser without local storage boots knowing it"
  (setup
    (local-storage-unavailable))
  (steps
    (expect-text (test-id "storage") "storage unavailable")
  )
)
