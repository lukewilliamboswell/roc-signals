(test "prepared description disposal and keyed movement round trip"
  (setup (initial-time -9))
  (steps
    (expect-visible (test-id "region"))
    (expect-text (test-id "stamp") "-9")
    (expect-text (test-id "cell-above") "0/0")
    (click (role button :name "Reverse"))
    (click (role button :name "Reverse"))
    (click (role button :name "Toggle"))
    (expect-absent (test-id "region"))
    (click (role button :name "Toggle"))
    (expect-text (test-id "cell-above") "0/0")
    (expect-text (test-id "local-above") "0/0")
    (expect-text (test-id "row-one") "one:0")))
