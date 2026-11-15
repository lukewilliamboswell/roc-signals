(test "A range's bounds, an empty control's pattern and minlength, a textarea's pattern and step any never block a submission"
  (setup (initial-location "/#effective-types"))
  (steps
    (fill (label "Notes") "zzz")
    (fill (label "Amount") "4")
    (submit (role form :name "Constraints"))
    (expect-text (test-id "submitted-Constraints") "1")))
