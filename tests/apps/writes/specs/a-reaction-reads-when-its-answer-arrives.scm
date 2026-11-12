(test "Writes — a reaction decides its writes from what it reads when its answer arrives and the value it was issued for"
  (steps
    (click (role button :name "Swap"))
    (expect-text (test-id "log") "log=left 2 right 1")
    (click (role button :name "Grow left"))
    (expect-text (test-id "log") "log=left 3 right 1")
  ))
