(test "Deployment ceilings refuse bytes and KDF cost without poisoning"
  (setup (max-crypto-bytes 64) (max-crypto-iterations 1000))
  (steps
    (click (role button :name "Random large"))
    (run-effect 1)
    (expect-text (test-id "result") "failed TooLarge")
    (click (role button :name "Too many iterations"))
    (run-effect 2)
    (expect-text (test-id "result") "failed TooLarge")
    (click (role button :name "Unlock SHA-256"))
    (run-effect 3)
    (expect-text (test-id "key") "unlocked")
    (click (role button :name "Lock"))
    (expect-keys 0)))
