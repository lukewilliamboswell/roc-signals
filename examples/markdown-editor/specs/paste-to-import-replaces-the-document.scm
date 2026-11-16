(test "Markdown editor — paste to import replaces the document"
  (steps
    (focus (label "Markdown source"))
    (paste-text (label "Paste to import") "# Pasted\n\nA new document.")
    (expect-value (label "Markdown source") "# Pasted\n\nA new document.")
    (expect-session-storage "md.draft" "# Pasted\n\nA new document.")
    (expect-visible (text "Pasted"))
    (expect-text (test-id "document-status") "Unsaved changes"))
)
