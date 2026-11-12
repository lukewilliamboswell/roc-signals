(test "Status page — The feed ending offers to reconnect"
  (steps
    (emit-port "roc-signals.example/status-page/latency" "{\"seq\":1,\"at_ms\":\"1762852800250\",\"p95_ms\":{\"api\":140,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}")
    (expect-absent (role button :name "Reconnect"))

    ; The feed's JavaScript fails: the subscription ends, the page says
    ; why and offers to reconnect.
    (fail-port "roc-signals.example/status-page/latency" "socket reset")
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 0)
    (expect-text (test-id "live-status") "The feed failed: socket reset")
    (click (role button :name "Reconnect"))
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
    (expect-text (test-id "live-status") "Connecting to the latency feed")
    (expect-absent (role button :name "Reconnect"))

    ; The feed closes: the same, in its own words.
    (close-port "roc-signals.example/status-page/latency")
    (expect-text (test-id "live-status") "The feed closed")
    (click (role button :name "Reconnect"))
    (emit-port "roc-signals.example/status-page/latency" "{\"seq\":90,\"at_ms\":\"1762852822500\",\"p95_ms\":{\"api\":150,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}")
    (expect-text (test-id "live-received") "2")
    (expect-text (test-id "live-api-p95") "150 ms")
  )
)
