(test "Status page — Pausing or hiding the page unsubscribes the feed"
  (steps
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":1,\"at_ms\":\"1762852800250\",\"p95_ms\":{\"api\":140,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")

    ; Pausing disposes the subscription's site, which ends the
    ; subscription (the feed's JavaScript is told to stop) and the chart's
    ; redraw tick. The readings already kept stay on the chart.
    (mark-metrics)
    (click (role button :name "Pause the feed"))
    (expect-metric-delta effects_cancelled 2)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 0)
    (expect-text (test-id "live-status") "Paused: the feed is unsubscribed until you resume")
    (expect-text (test-id "live-received") "1")

    ; Resuming subscribes afresh.
    (click (role button :name "Resume the feed"))
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
    (expect-text (test-id "live-status") "Connecting to the latency feed")
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":41,\"at_ms\":\"1762852810250\",\"p95_ms\":{\"api\":141,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")
    (expect-text (test-id "live-received") "2")

    ; A hidden page has no feed, as it has no polling; showing it again
    ; subscribes afresh.
    (set-visibility hidden)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 0)
    (set-visibility visible)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)

    ; A page hidden while paused stays paused when shown.
    (click (role button :name "Pause the feed"))
    (set-visibility hidden)
    (set-visibility visible)
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 0)
  )
)
