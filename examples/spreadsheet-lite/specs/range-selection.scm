(test "Shift arrows extend a rectangle and Escape collapses it"
  (steps
    (press (label "B2") "Shift+ArrowRight")
    (press "Shift+ArrowRight")
    (press "Shift+ArrowDown")
    (press "Shift+ArrowDown")
    (expect-focused (label "D4"))
    (expect-text (test-id "stat-selection") "B2:D4 · 8200")
    (press "Escape")
    (expect-focused (label "D4"))
    (expect-text (test-id "stat-selection") "D4 · 400")))
