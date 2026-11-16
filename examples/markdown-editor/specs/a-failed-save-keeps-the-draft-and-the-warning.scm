(test "Markdown editor — a failed save keeps the draft and the warning"
  (setup
    (local-storage "md.document" "# Previously saved")
    (local-storage-full))
  (steps
    (fill (label "Markdown source") "# Unsaved")
    (click (role button :name "Save"))
    (expect-local-storage "md.document" "# Previously saved")
    (expect-session-storage "md.draft" "# Unsaved")
    (expect-text (test-id "document-status") "Unsaved changes")
    (expect-text (test-id "save-status") "This document is too large to save")
    (leave-page "/not-yet" stay)
    (expect-value (label "Markdown source") "# Unsaved")
    (leave-page "/restored" leave)
    (expect-value (label "Markdown source") "# Unsaved")
    (expect-text (test-id "document-status") "Unsaved changes")
    (expect-local-storage "md.document" "# Previously saved")
    (expect-session-storage "md.draft" "# Unsaved"))
)
