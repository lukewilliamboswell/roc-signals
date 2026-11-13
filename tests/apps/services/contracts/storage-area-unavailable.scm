(test "An unavailable local storage getter cannot identify a report source"
  (setup
    (initial-location "/#storage")
    (local-storage-unavailable))
  (steps
    (storage-elsewhere "document" "remote")
    (expect-text (test-id "storage-change") "initial")))
