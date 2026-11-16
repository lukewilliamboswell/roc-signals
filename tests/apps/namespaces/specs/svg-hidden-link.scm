(test "HTML's hidden attribute neither hides an SVG link nor stops its focus"
  (steps
    (expect-element (test-id "svg-hidden-link") svg "a")
    (focus (test-id "svg-hidden-link"))
    (expect-focused (test-id "svg-hidden-link"))
    (click (test-id "svg-hidden-link"))
    (expect-current-location "/#svg-link")))
