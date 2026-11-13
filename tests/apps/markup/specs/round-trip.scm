(test "markup round trip restores text, rows and conditional lifetime"
  (steps
    (mark-metrics)
    (click (role button :name "Step"))
    (expect-text (test-id "literal-count") "1")
    (click (role button :name "Swap rows"))
    (click (role button :name "Toggle region"))
    (expect-absent (test-id "literal-region"))
    (click (role button :name "Reset"))
    (expect-text (test-id "literal-count") "0")
    (expect-text (test-id "literal-region") "first")
    (expect-text (test-id "html-one") "one")
    (expect-element (test-id "foreign-one") html "div")))
