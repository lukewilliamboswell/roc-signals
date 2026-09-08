(test "checkbox enables an action and updates selected native presentation"
  (steps
    (expect-disabled (test-id "run-action") true)
    (check (label "Enable action"))
    (expect-checked (label "Enable action") true)
    (expect-disabled (test-id "run-action") false)
    (click (test-id "run-action"))
    (expect-visible (text "Runs: 1"))
    (uncheck (label "Enable action"))
    (expect-disabled (test-id "run-action") true)))
