(test "Services — connectivity comes from boot and follows the browser"
  (setup
    (initial-online offline))
  (steps
    (expect-text (test-id "online") "offline")
    (set-online online)
    (expect-text (test-id "online") "online")
    (set-online offline)
    (expect-text (test-id "online") "offline")
  )
)
