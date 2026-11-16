(test "Top layer — inline close hides before removing focused contents"
  (setup (initial-location "/#top-layer"))
  (steps
    (click (role button :name "Open inline"))
    (expect-shown (label "Inline") open)
    (expect-focused (label "Inline first"))
    (dismiss)
    (expect-shown (label "Inline") open)
    (click (role button :name "Close inline"))
    (expect-shown (label "Inline") hidden)
    (expect-focused (role button :name "Open inline"))
    (expect-absent (label "Inline first"))))
