(test "Markdown editor — a draft too large says so"
  (setup
    (session-storage "md.draft" "# Previous draft")
    (session-storage-full))
  (steps
    (fill (label "Markdown source") "# New draft")
    (expect-value (label "Markdown source") "# New draft")
    (expect-session-storage "md.draft" "# Previous draft")
    (expect-text (test-id "draft-status") "This draft is too large to keep")
    (expect-text (test-id "document-status") "Unsaved changes"))
)
