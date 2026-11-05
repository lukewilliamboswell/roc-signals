(test "a search shows its results, and a failed one says why"
  (setup
    (manual-effects))
  (steps
    (expect-pending-effects 0)
    (fill (label "Query") "roc")
    (real-click (role button :name "Search"))
    (expect-text (test-id "results") "Searching…")
    (expect-pending-effects 1)
    (stub-http "roc results" :url "/api/search?q=roc" :status 200 :body "3 results")
    (run-effect 1)
    (expect-text (test-id "results") "3 results")
    ; Searching again for the same query issues a second request.
    (submit (role form :name "Search"))
    (stub-http-reject "offline" :kind network :detail "offline")
    (run-effect 2)
    (expect-text (test-id "results") "Search failed: Network(\"offline\")")))
