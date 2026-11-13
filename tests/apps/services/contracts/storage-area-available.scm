(test "An identifiable local storage area reports another document's write"
  (setup (initial-location "/#storage"))
  (steps
    (storage-elsewhere "document" "remote")
    (expect-text (test-id "storage-change") "remote")))
