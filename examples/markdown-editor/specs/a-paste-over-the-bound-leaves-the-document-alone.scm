(test "Markdown editor — a paste over the bound leaves the document alone"
  (setup
    (local-storage "md.document" "# Original")
    (max-paste-bytes 4))
  (steps
    ; Three two-byte scalars cross the byte bound, though there are only three characters.
    (paste-text (label "Paste to import") "ééé")
    (expect-value (label "Markdown source") "# Original")
    (expect-no-session-storage "md.draft")
    (expect-text (test-id "document-status") "Saved")
    (expect-text (test-id "paste-status") "Pasted text is too large to import"))
)
