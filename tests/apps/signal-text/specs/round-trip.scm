(test "signal text round trip returns to the same selected row"
  (steps
    (mark-metrics)
    (click (role button :name "Choose row-1"))
    (click (role button :name "Choose row-2"))
    (expect-text (test-id "choice-row-2") "row-2")
    (expect-attr (test-id "choice-row-2") data-choice "yes row-2")
    (click (role button :name "Choose row-0"))
    (expect-text (test-id "choice-row-0") "row-0")
    (expect-attr (test-id "choice-row-0") data-choice "yes row-0")))
