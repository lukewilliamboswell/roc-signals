(test "Status page — Pausing while reconnecting cancels the retry"
  (setup (seed 7))
  (steps
    (close-port "roc-signals.example/status-page/latency")
    (expect-text (test-id "live-status") "Connection lost: reconnecting in 1.160 s (attempt 1)")
    (mark-metrics)
    (click (role button :name "Pause the feed"))
    (expect-metric-delta effects_cancelled 1)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 0)
    (expect-pending-effects 5)
    (click (role button :name "Resume the feed"))
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
  )
)
