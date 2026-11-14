(test "Status page — A failed or closed feed starts a backoff"
  (setup (seed 7))
  (steps
    (fail-port "roc-signals.example/status-page/latency" "socket reset")
    (expect-text (test-id "live-status") "Connection lost: reconnecting in 1.160 s (attempt 1)")
    (run-effect 6)
    (close-port "roc-signals.example/status-page/latency")
    (expect-text (test-id "live-status") "Connection lost: reconnecting in 2.432 s (attempt 2)")
    (expect-absent (role button :name "Reconnect") :never-drawn)
    (run-effect 7)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
  )
)
