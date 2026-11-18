(test "ordinary body round trip keeps current state and remounts fresh"
  (setup (initial-location "/direct-small/"))
  (steps
    (expect-text (test-id "value") "0")
    (click (role button :name "Bump"))
    (expect-text (test-id "value") "1")
    (click (role button :name "Toggle region"))
    (expect-absent (test-id "value"))
    (click (role button :name "Toggle region"))
    (expect-text (test-id "value") "0")))
