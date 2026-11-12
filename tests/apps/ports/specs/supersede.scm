(test "Ports — a newer value of a latest site stops the older call, whose late answer is stale"
  (steps
    (click (role button :name "Get"))
    (mark-metrics)
    (click (role button :name "Get"))
    (expect-metric-delta effects_cancelled 1)
    (expect-pending-effects 1)
    (expect-port-call 2 "test.roc-signals/get" "{\"key\":\"k2\"}")
    (answer-port 2 reply "{\"value\":\"two\"}")
    (expect-text (test-id "log") "get k2:two")
  )
)
