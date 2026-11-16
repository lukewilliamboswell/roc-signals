(test "Focus and blur on a list item with no text value run with an empty value in both runners"
  (steps
    (focus (label "Focusable item"))
    (expect-focused (label "Focusable item"))
    (expect-text (test-id "log") "item-focus:")
    (blur (label "Focusable item"))
    (expect-no-focus)
    (expect-text (test-id "log") "item-focus:|item-blur:")))
