(test "Pasting without a listener preserves held storage reports"
  (setup (initial-location "/#storage"))
  (steps
    (hold-reports)
    (storage-elsewhere "document" "changed")
    (paste-text (test-id "storage-change") "ignored")
    (expect-text (test-id "storage-change") "initial")
    (release-reports)
    (expect-text (test-id "storage-change") "changed")))
