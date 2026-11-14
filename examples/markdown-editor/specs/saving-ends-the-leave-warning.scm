(test "Markdown editor — saving ends the leave warning"
  (steps
    (fill (label "Markdown source") "# Kept")
    (click (role button :name "Save"))
    (expect-local-storage "md.document" "# Kept")
    (expect-session-storage "md.draft" "# Kept")
    (expect-text (test-id "document-status") "Saved")
    (leave-page "/saved" unasked)
    (expect-value (label "Markdown source") "# Kept")
    ; Retained drafts start dirty conservatively: boot never compares two large texts.
    (expect-text (test-id "document-status") "Unsaved changes"))
)
