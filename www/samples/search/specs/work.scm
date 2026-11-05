(test "a result rewrites one text node and nothing else"
  (steps
    (fill (label "Query") "roc")
    (submit (role form :name "Search"))
    (stub-http "results" :url "/api/search?q=roc" :status 200 :body "3 results")
    (mark-metrics)
    (run-effect 1)
    (expect-metric-delta set_text 1)
    (expect-metric-delta create_element 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta-at-most derived_calls_into_roc 5)
    (expect-updates (test-id "results") 3)))
