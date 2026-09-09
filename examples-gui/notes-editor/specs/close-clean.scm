(test "A clean document closes immediately"
  (steps (request-window-close) (expect-window-closed true)))
