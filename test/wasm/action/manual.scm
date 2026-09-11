(test "manual effects preserve each prepared occurrence and chained commits"
  (setup (manual-effects))
  (steps
    (click (text "Run"))
    (expect-visible (text "Count: 1"))
    (expect-pending-effects 1)
    (run-effect 1)
    (expect-pending-effects 1)
    (run-effect 2)
    (expect-pending-effects 0)
    (expect-visible (text "Count: 4"))
    ; Leave a prepared thunk for the normal spec teardown ownership checks.
    (click (text "Run"))
    (expect-visible (text "Count: 5"))
    (expect-pending-effects 1)))
