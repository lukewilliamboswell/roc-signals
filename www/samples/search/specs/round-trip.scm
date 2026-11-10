(test "a search answered and its query cleared can repeat without leaving anything allocated"
  (steps
    ; Set the scene: nothing here is repeated by a soak.
    (expect-pending-effects 0)
    ; The round trip: `--soak` repeats every call from here on.
    (mark-metrics)
    (fill (label "Query") "roc")
    (submit (role form :name "Search"))
    (stub-http "roc results" :url "/api/search?q=roc" :status 200 :body "3 results")
    (run-effect 1)
    (expect-text (test-id "results") "3 results")
    (fill (label "Query") "")
    (expect-pending-effects 0)))
