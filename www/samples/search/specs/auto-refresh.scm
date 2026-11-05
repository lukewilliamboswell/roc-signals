(test "auto-refresh refetches on its interval and stops when unchecked"
  (setup
    (manual-effects))
  (steps
    (fill (label "Query") "roc")
    (submit (role form :name "Search"))
    (stub-http "first" :url "/api/search?q=roc" :status 200 :body "3 results")
    (run-effect 1)
    (expect-interval 30000 0)
    (check (label "Auto-refresh"))
    (expect-interval 30000 1)
    (tick-interval 30000)
    (expect-pending-effects 1)
    (stub-http "second" :url "/api/search?q=roc" :status 200 :body "4 results")
    (run-effect 2)
    (expect-text (test-id "results") "4 results")
    (uncheck (label "Auto-refresh"))
    (expect-interval 30000 0)))
