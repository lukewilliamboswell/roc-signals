(test "Million-Row Explorer — every shard is asked at once, each shows as it answers, and the charts wait for the last"
  (setup (initial-location "/?orders=200000"))
  (steps
    ; The mount generates the four shards of the database the address names.
    (expect-text (test-id "size") "200,000 orders. Generate")
    (expect-pending-work "roc-signals.example/million-row-explorer/summary" 4)
    (expect-text (test-id "status") "Generating 200,000 orders in 4 workers… 0 of 4 shards ready.")
    ; The shards answer in any order; the totals wait for all four.
    (run-effect 3)
    (expect-text (test-id "shard-3") "50,000 match")
    (expect-text (test-id "shard-1") "asking…")
    (expect-text (test-id "orders") "0")
    (run-effect 1)
    (run-effect 4)
    (expect-text (test-id "status") "Generating 200,000 orders in 4 workers… 3 of 4 shards ready.")
    (run-effect 2)
    (expect-text (test-id "status") "4 of 4 shards answered.")
    (expect-text (test-id "orders") "200,000")
    (expect-text (test-id "revenue") "$14,762,665")
    (expect-text (test-id "average") "$73.81")
  )
)
