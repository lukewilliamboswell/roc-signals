(test "Document shortcuts work outside the grid"
  (steps
    (focus (role button :name "Hide empty rows"))
    (press "Control+`")
    (expect-text (test-id "stat-mode") "Formulas")
    (expect-value (label "D2") "=B2+C2")
    (press "Control+`")
    (expect-text (test-id "stat-mode") "Values")
    (press (label "B2") "Shift+ArrowRight")
    (focus (role button :name "Hide empty rows"))
    (press "Escape")
    (expect-text (test-id "stat-selection") "C2 · 1300")))
