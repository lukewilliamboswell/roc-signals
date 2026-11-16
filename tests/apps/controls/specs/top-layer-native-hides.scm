(test "Top layer — showing an unrelated auto popover or modal echoes native hides"
  (setup (initial-location "/#top-layer"))
  (steps
    (click (role button :name "Open auto A"))
    (click (role button :name "Open B from A"))
    (expect-shown (label "Auto A") hidden)
    (expect-shown (label "Auto B") popover)
    (click (role button :name "Open modal from B"))
    (expect-shown (label "Auto B") hidden)
    (expect-shown (label "Modal") modal)
    (dismiss)
    (expect-shown (label "Modal") hidden)))
