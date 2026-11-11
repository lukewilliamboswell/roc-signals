(test "Status page — Dropping the connection tells the feed"
  (steps
    ; The button posts to an outbox, and an `on_post` site sends the
    ; command in the same turn. Every click is sent, an equal one included.
    (expect-port-sends "roc-signals.example/status-page/disconnect" 0)
    (click (role button :name "Drop the connection for 20 s"))
    (expect-port-sends "roc-signals.example/status-page/disconnect" 1)
    (expect-port-sent "roc-signals.example/status-page/disconnect" 1 "{\"seconds\":20}")
    (click (role button :name "Drop the connection for 20 s"))
    (expect-port-sends "roc-signals.example/status-page/disconnect" 2)

    ; The page learns what the outage cost from the feed itself: the
    ; readings it replays, and the count it dropped.
    (emit-port "roc-signals.example/status-page/latency" "{\"seq\":96,\"at_ms\":\"1762852824000\",\"p95_ms\":{\"api\":140,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":16}")
    (expect-text (test-id "live-dropped") "16")
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
  )
)
