(test "Markdown editor — copy denied shows a message"
  (setup (clipboard-denied))
  (steps
    (fill (label "Markdown source") "# Copy this")
    (click (role button :name "Copy as markdown"))
    (expect-text (test-id "copy-status") "Copy blocked by the browser")
    (expect-value (label "Markdown source") "# Copy this"))
)
