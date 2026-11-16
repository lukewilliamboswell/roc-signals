(test "Declarations without initialization"
  (setup (initial-media "screen" true) (local-storage "seeded" "value"))
  (steps
    (expect-port-sends "command" 0)
    (expect-port-subscriptions "subscription" 0)
    (expect-port-call 1 "call" "null")
    (expect-pending-work "task" 0)
    (expect-pending-work "empty-owner" 0)
    (expect-media-subscriptions "screen" 0)
    (expect-no-local-storage "local")
    (expect-no-session-storage "session")
    (expect-no-local-storage "seeded")
    (expect-no-local-storage "positive")
    (expect-local-storage "positive" "value")))
