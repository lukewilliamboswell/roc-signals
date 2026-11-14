(test "Attribute presence reads empty text and explicit live control readings"
  (steps
    (expect-has-attr (test-id "attribute-plain") alt)
    (expect-attr (test-id "attribute-plain") alt "")
    (expect-has-attr (label "Plain") value)
    (expect-has-attr (label "Plain") checked)
    (expect-has-attr (label "Plain") disabled)
    (expect-value (label "Plain") "hello world")
    (expect-checked (label "Plain") false)
    (expect-disabled (label "Plain") false)))
