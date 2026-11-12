(test "Supersede — the latest search wins: the earlier request is cancelled"
  (steps
    (click (role button :name "Search A"))
    (expect-pending-effects 1)
    (click (role button :name "Search B"))
    ; A's request was cancelled before B's was issued: one is pending.
    (expect-pending-effects 1)
    (stub-http "b" :url "/search?q=b" :status 200 :body "beta")
    (run-effect 2)
    (expect-text (test-id "results") "b:beta")
    (expect-pending-effects 0)
  )
)
