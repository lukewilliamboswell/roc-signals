(test "Keyboard range and edit round trip"
  (steps
    (focus (label "B2"))
    (mark-metrics)
    (press "Shift+ArrowRight")
    (press "Escape")
    (press "ArrowLeft")
    (fill (label "B2") "1600")
    (press "Escape")
    (expect-value (label "B2") "1200")
    (expect-focused (label "B2"))))
