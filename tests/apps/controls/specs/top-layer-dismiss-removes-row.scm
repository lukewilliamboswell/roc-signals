(test "Top layer — a row whose popover's dismissal removes the row releases it once"
  (setup (initial-location "/#top-layer"))
  (steps
    (click (role button :name "Show dismissable rows"))
    (expect-shown (test-id "dismissable-x") popover)
    (click (role button :name "Outside"))
    (expect-absent (test-id "dismissable-x"))
    (click (role button :name "Show dismissable rows"))
    (expect-shown (test-id "dismissable-x") popover)
    (dismiss)
    (expect-absent (test-id "dismissable-x"))))
