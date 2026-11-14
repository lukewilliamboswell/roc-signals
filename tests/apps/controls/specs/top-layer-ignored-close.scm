(test "Top layer — a close with no writes reopens from the controlled signal"
  (setup (initial-location "/#top-layer"))
  (steps
    (click (role button :name "Open ignored"))
    (expect-shown (label "Ignored") modal)
    (dismiss)
    (expect-shown (label "Ignored") modal)
    (expect-focused (role button :name "Close ignored"))
    (click (role button :name "Close ignored"))
    (expect-shown (label "Ignored") hidden)))
