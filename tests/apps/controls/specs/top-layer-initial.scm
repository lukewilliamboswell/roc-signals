(test "Top layer — plain popovers mount both initial showing states after their mode attribute"
  (setup (initial-location "/#top-layer"))
  (steps
    (expect-shown (label "Initially shown") popover)
    (expect-shown (label "Auto A") hidden)
    (click (role button :name "Close initially shown"))
    (expect-shown (label "Initially shown") hidden)
    (click (role button :name "Open auto A"))
    (expect-shown (label "Auto A") popover)
    (dismiss)
    (expect-shown (label "Auto A") hidden)))
