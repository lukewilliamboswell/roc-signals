(test "Malformed cryptographic parameters are typed failures"
  (steps
    (click (role button :name "Invalid salt"))
    (expect-text (test-id "result") "failed InvalidParameters")
    (click (role button :name "Zero iterations"))
    (expect-text (test-id "result") "failed InvalidParameters")
    (click (role button :name "Unlock SHA-256"))
    (run-effect 1)
    (click (role button :name "Seal"))
    (run-effect 2)
    (click (role button :name "Invalid IV"))
    (expect-text (test-id "result") "failed InvalidParameters")
    (click (role button :name "Lock"))
    (expect-keys 0)))
