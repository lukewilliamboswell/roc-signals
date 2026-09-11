(test "web action chains snapshot each committed batch and preserve occurrences"
  (steps
    (expect-visible (text "Count: 0"))
    (click (text "Run"))
    (expect-visible (text "Count: 4"))
    (click (text "Run"))
    (expect-visible (text "Count: 20"))))
