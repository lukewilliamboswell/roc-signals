(test "the typed corpus settles acknowledgement and live snapshot effects"
  (steps
    (expect-text (test-id "route") "first")
    (expect-text (test-id "counter") "1")
    (expect-text (test-id "environment") "snapshot|/snapshot-ready?query#fragment|ack")
    (expect-value (test-id "textarea") "live text")
    (expect-checked (test-id "authored-inert") true)
    (expect-text (test-id "tail-a") "a")
    (click (test-id "increment"))
    (expect-text (test-id "counter") "2")
    (expect-text (test-id "waiting") "Static waiting")
    (run-opportunity)
    (expect-text (test-id "active") "Live active")
    (expect-absent (test-id "waiting"))))
