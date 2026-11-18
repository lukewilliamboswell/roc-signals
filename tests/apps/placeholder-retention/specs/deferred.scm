(test "one-shot body round trip disposes payload and remounts waiting"
  (setup (initial-location "/deferred-large/"))
  (steps
    (expect-text (test-id "waiting") "waiting")
    (run-opportunity)
    (expect-absent (test-id "waiting"))
    (expect-text (test-id "value") "0")
    (click (role button :name "Bump"))
    (expect-text (test-id "value") "1")
    (click (role button :name "Toggle region"))
    (expect-absent (test-id "value"))
    (click (role button :name "Toggle region"))
    (expect-text (test-id "waiting") "waiting")))
