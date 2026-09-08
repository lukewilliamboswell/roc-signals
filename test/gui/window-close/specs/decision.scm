(test "Only a pending native close can consume an explicit decision"
  (steps
    (click (role button :name "Approve close"))
    (expect-window-closed false)
    (request-window-close)
    (expect-visible (text "Deciding"))
    (expect-window-closed false)
    (click (role button :name "Keep open"))
    (expect-window-closed false)
    (click (role button :name "Approve close"))
    (expect-window-closed false)
    (request-window-close)
    (click (role button :name "Approve close"))
    (expect-window-closed true)))
