(test "Status page — A reading that breaks the feed's rules is rejected at the door"
  (steps
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":7,\"at_ms\":\"1762852801750\",\"p95_ms\":{\"api\":140,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")
    (expect-text (test-id "live-received") "1")

    ; A reading that does not come after the newest one kept, a message
    ; that is not a reading, and a time no chart can place are each
    ; refused and counted. None of them ends the feed or reaches the chart.
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":7,\"at_ms\":\"1762852801750\",\"p95_ms\":{\"api\":999,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":8,\"p95_ms\":{\"api\":140}}}")
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":9,\"at_ms\":\"-99999999999999999\",\"p95_ms\":{\"api\":140,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")
    (expect-text (test-id "live-rejected") "3")
    (expect-text (test-id "live-received") "1")
    (expect-text (test-id "live-api-p95") "140 ms")
    (expect-text (test-id "live-status") "Live: a reading of every service's p95 every 250 ms")
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)

    ; The next good reading is kept.
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":8,\"at_ms\":\"1762852802000\",\"p95_ms\":{\"api\":145,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")
    (expect-text (test-id "live-received") "2")
    (expect-text (test-id "live-api-p95") "145 ms")
  )
)
