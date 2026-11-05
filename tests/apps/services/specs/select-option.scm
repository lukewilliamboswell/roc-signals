(test "Services — select-option picks a rendered option; a select keeps its value when options mount after it"
  (steps
    (expect-value (label "Fruit") "apple")
    (select-option (label "Fruit") "pear")
    (expect-value (label "Fruit") "pear")
    (expect-text (test-id "fruit") "pear")
    (expect-value (label "Shade") "teal")
    (select-option (label "Shade") "plum")
    (expect-value (label "Shade") "plum")
  )
)
