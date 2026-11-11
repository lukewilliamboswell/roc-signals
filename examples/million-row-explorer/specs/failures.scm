(test "Million-Row Explorer — a shard that times out or loses its worker fails the question, says which, and the next question asks again"
  (steps
    (select-option (label "Orders in the database") "200000")
    (run-effect 5)
    (run-effect 6)
    (run-effect 7)
    (run-effect 8)
    (expect-text (test-id "orders") "200,000")
    (uncheck (label "Books"))
    ; The first shard's deadline expires and the third's worker crashes;
    ; the others answer.
    (time-out-work 9)
    (expect-text (test-id "shard-1") "timed out")
    (expect-text (test-id "status") "Asking 4 shards… 0 answered; the charts show the last complete answer.")
    (run-effect 10)
    (lose-work 11 app_crash)
    (run-effect 12)
    (expect-text (test-id "shard-3") "worker lost")
    (expect-text (test-id "shard-4") "43,050 match")
    ; The whole answer fails with the first failure in shard order.
    (expect-text (test-id "status") "A shard took too long to answer. Only today's live orders are shown; change the question to ask again.")
    (expect-text (test-id "orders") "0")
    ; Asking again works.
    (check (label "Books"))
    (expect-pending-work "roc-signals.example/million-row-explorer/summary" 4)
    (run-effect 13)
    (run-effect 14)
    (run-effect 15)
    (run-effect 16)
    (expect-text (test-id "status") "4 of 4 shards answered.")
    (expect-text (test-id "orders") "200,000")
  )
)
