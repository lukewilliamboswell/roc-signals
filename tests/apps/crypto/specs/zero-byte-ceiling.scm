(test "A zero input ceiling allows empty randomness and a fixed-size digest"
  (setup (max-crypto-bytes 0))
  (steps
    (click (role button :name "Random zero"))
    (run-effect 1)
    (expect-text (test-id "result") "random 0")
    (click (role button :name "Empty SHA-512"))
    (run-effect 2)
    (expect-text (test-id "result") "digest z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg==")
    (click (role button :name "New salt"))
    (run-effect 3)
    (expect-text (test-id "result") "failed TooLarge")
    (expect-pending-effects 0)
    (expect-keys 0)))
