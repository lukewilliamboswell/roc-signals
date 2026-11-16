(test "A position can be requested once or followed in a scoped subscription"
  (steps
    (click (role button :name "Find location"))
    (expect-port-call 1 "example.org/recipes/location" "{}")
    (answer-port 1 reply "{\"accuracy\":3,\"latitude\":1,\"longitude\":2}")
    (expect-text (test-id "location-result") "1, 2 (±3 m)")
    (click (role button :name "Toggle location watch"))
    (expect-port-subscriptions "example.org/recipes/positions" 1)
    (emit-port "example.org/recipes/positions" "{\"accuracy\":6,\"latitude\":4,\"longitude\":5}")
    (expect-text (test-id "position-result") "4, 5 (±6 m)")
    (click (role button :name "Toggle location watch"))
    (expect-port-subscriptions "example.org/recipes/positions" 0)))
