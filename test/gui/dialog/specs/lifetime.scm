(test "Dialog label and Escape binding belong to its explicit scope"
  (steps
    (expect-absent (role dialog :name "Confirm changes"))
    (click (role button :name "Open dialog"))
    (expect-visible (role dialog :name "Confirm changes"))
    (fill (label "Reason") "Review this change")
    (shortcut (role dialog :name "Confirm changes") "Escape" 0)
    (expect-absent (test-id "confirmation"))
    (click (role button :name "Open dialog"))
    (expect-value (label "Reason") "")
    (click (role button :name "Keep editing"))
    (expect-absent (role dialog :name "Confirm changes"))
))
