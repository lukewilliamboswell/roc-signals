(test "Million-Row Explorer — a shard that times out or loses its worker fails the question, says which, and the next question asks again"
  (setup (initial-location "/?orders=200000"))
  (steps
    (run-effect 1)
    (run-effect 2)
    (run-effect 3)
    (run-effect 4)
    (expect-text (test-id "orders") "200,000")
    (uncheck (label "Books"))
    ; The first shard's deadline expires and the third's worker crashes;
    ; the others answer.
    (time-out-work 5)
    (expect-text (test-id "shard-1") "timed out")
    (expect-text (test-id "status") "Asking 4 shards… 0 answered; the charts show the last complete answer.")
    (run-effect 6)
    (lose-work 7 app_crash)
    (run-effect 8)
    (expect-text (test-id "shard-3") "worker lost")
    (expect-text (test-id "shard-4") "43,050 match")
    ; The whole answer fails with the first failure in shard order.
    (expect-text (test-id "status") "A shard took too long to answer. Only today's live orders are shown; change the question to ask again.")
    (expect-text (test-id "orders") "0")
    ; Asking again works.
    (check (label "Books"))
    (expect-pending-work "roc-signals.example/million-row-explorer/summary" 4)
    (run-effect 9)
    (run-effect 10)
    (run-effect 11)
    (run-effect 12)
    (expect-text (test-id "status") "4 of 4 shards answered.")
    (expect-text (test-id "orders") "200,000")
  )
)
