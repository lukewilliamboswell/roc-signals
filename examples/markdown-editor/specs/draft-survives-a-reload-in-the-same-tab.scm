(test "Markdown editor — draft survives a reload in the same tab"
  (setup
    (local-storage "md.document" "# Saved")
    (session-storage "md.draft" "# Previous draft"))
  (steps
    (expect-value (label "Markdown source") "# Previous draft")
    (expect-text (test-id "document-status") "Unsaved changes")
    (fill (label "Markdown source") "# New draft")
    (expect-session-storage "md.draft" "# New draft")
    (leave-page "/" leave)
    (expect-value (label "Markdown source") "# New draft")
    (expect-text (test-id "document-status") "Unsaved changes")
    (expect-local-storage "md.document" "# Saved")
    ; Same-origin reloads retain sticky activation. The restored dirty draft
    ; therefore asks again, even without an input step in this new document.
    (leave-page "/still-dirty" leave)
    (expect-value (label "Markdown source") "# New draft"))
)
