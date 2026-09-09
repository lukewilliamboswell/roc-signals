(test "Discarding on close is explicit and repeated native requests do not close early"
 (steps
  (request-window-close)
  (request-window-close)
  (expect-window-closed false)
  (click (role button :name "Close without saving"))
  (expect-window-closed true)
 ))
