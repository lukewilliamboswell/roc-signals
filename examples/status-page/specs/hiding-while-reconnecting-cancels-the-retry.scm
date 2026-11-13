(test "Status page — hiding while reconnecting cancels the retry"
  (setup (seed 7))
  (steps
    (close-port "roc-signals.example/status-page/latency")
    (mark-metrics)
    (set-visibility hidden)
    ; The retry timer and the page's five-second polling interval stop.
    (expect-metric-delta effects_cancelled 2)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 0)
    (set-visibility visible)
    (expect-text (test-id "live-status") "Connecting to the latency feed")
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
  )
)
