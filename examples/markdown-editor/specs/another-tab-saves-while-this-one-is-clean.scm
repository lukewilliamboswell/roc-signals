(test "Markdown editor — another tab saves while this one is clean"
  (setup (local-storage "md.document" "# Original"))
  (steps
    (expect-text (test-id "document-status") "Saved")
    (focus (label "Markdown source"))
    (storage-elsewhere "md.document" "# Remote")
    (expect-value (label "Markdown source") "# Remote")
    (expect-session-storage "md.draft" "# Remote")
    (expect-text (test-id "document-status") "Saved")
    (expect-absent (role button :name "Keep mine") :never-drawn))
)
