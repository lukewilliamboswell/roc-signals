(test "Markdown editor — session storage unavailable still edits"
  (setup (session-storage-unavailable))
  (steps
    (expect-text (test-id "draft-status") "Session drafts are unavailable; keep a copy before leaving.")
    (fill (label "Markdown source") "# Still editing")
    (expect-value (label "Markdown source") "# Still editing")
    (expect-text (test-id "draft-status") "Session drafts are unavailable; keep a copy before leaving.")
    (expect-text (test-id "document-status") "Unsaved changes")
    (expect-no-session-storage "md.draft"))
)
