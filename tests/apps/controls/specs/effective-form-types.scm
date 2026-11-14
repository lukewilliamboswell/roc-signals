(test "Invalid input and button types use HTML submission defaults"
  (setup (initial-location "/#effective-types"))
  (steps
    (press (label "one input") "Enter")
    (expect-text (test-id "submitted-one") "1")
    (press (label "two input") "Enter")
    (expect-text (test-id "submitted-two") "0")
    (expect-attr (role button :name "Invalid submit button") "type" "sumbit")
    (click (role button :name "Invalid submit button"))
    (expect-text (test-id "submitted-button") "1")))
