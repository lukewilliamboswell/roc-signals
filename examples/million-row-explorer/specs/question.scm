(test "Million-Row Explorer — a click asks at once, a slider asks when its sampling timer fires, and the last complete answer stays until every shard has answered"
  (setup (initial-location "/?orders=200000"))
  (steps
    (run-effect 1)
    (run-effect 2)
    (run-effect 3)
    (run-effect 4)
    (expect-text (test-id "orders") "200,000")
    ; Clearing a category asks every shard at once.
    (uncheck (label "Electronics"))
    (expect-pending-work "roc-signals.example/million-row-explorer/summary" 4)
    (expect-text (test-id "status") "Asking 4 shards… 0 answered; the charts show the last complete answer.")
    ; Two steps of a slider start one timer and ask nothing yet.
    (mark-metrics)
    (change (label "Lowest value") "4")
    (change (label "Lowest value") "5")
    (expect-text (test-id "range") "From $50 to $400")
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta effects_cancelled 0)
    (expect-pending-effects 5)
    ; The timer fires: the slider's last value is asked, and the four
    ; waiting jobs of the question before it stop.
    (run-effect 9)
    (expect-metric-delta effects_issued 5)
    (expect-metric-delta effects_cancelled 4)
    (expect-pending-work "roc-signals.example/million-row-explorer/summary" 4)
    ; Two shards answer: the totals are still the last complete answer.
    (run-effect 10)
    (run-effect 12)
    (expect-text (test-id "status") "Asking 4 shards… 2 answered; the charts show the last complete answer.")
    (expect-text (test-id "orders") "200,000")
    (expect-text (test-id "shard-1") "20,542 match")
    (expect-text (test-id "shard-2") "asking…")
    (run-effect 11)
    (run-effect 13)
    (expect-text (test-id "status") "4 of 4 shards answered.")
    (expect-text (test-id "orders") "82,281")
    (expect-text (test-id "revenue") "$6,839,487")
    ; Moving the highest end below the lowest takes the lowest with it.
    (change (label "Highest value") "2")
    (expect-text (test-id "range") "From $20 to $30")
  )
)
