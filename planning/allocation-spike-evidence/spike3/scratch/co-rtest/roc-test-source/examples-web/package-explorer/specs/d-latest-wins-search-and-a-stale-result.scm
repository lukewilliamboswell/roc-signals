(test "Package explorer — D. latest wins search and a stale result"
  (setup (manual-effects))
  (steps
    ; Complete the initial search before testing overlapping queries.
    (stub-http "search " :url "/api/packages/search?q=" :status 200 :body "roc-json|JSON codec for Roc;roc-http|HTTP client for Roc;roc-parser|Parser combinators for Roc")
    (run-effect 1)

    ; D. latest wins search and a stale result

    (fill (label "Search packages") "js")
    (expect-value (label "Search packages") "js")
    (expect-pending-effects 1)
    (expect-text (test-id "search-status") "Search status: searching")
    ; Typing again admits another effect; only its generation may publish.
    (fill (label "Search packages") "json")
    (expect-pending-effects 2)
    (mark-metrics)
    (stub-http "older js search" :url "/api/packages/search?q=%6a%73" :status 200 :body "stale-package|This superseded payload must never render")
    (run-effect 2)
    (expect-metric-delta patches_emitted 0)
    (expect-text (test-id "search-status") "Search status: searching")
    (expect-absent (role link :name "Open stale-package"))
    (expect-pending-effects 1)
    ; One matching package: the singular boundary case.
    (stub-http "search json" :url "/api/packages/search?q=%6a%73%6f%6e" :status 200 :body "roc-json|JSON codec for Roc")
    (run-effect 3)
    (expect-pending-effects 0)
    (expect-text (test-id "search-status") "Search status: 1 package")
    (expect-text (test-id "context") "Context: search results (1 matches)")
    (expect-visible (role link :name "Open roc-json"))
    (expect-absent (role link :name "Open roc-http"))
    ; No matches: the empty branch of the list.
    (fill (label "Search packages") "zzzz")
    (expect-pending-effects 1)
    (stub-http "search zzzz" :url "/api/packages/search?q=%7a%7a%7a%7a" :status 200 :body "")
    (run-effect 4)
    (expect-text (test-id "search-status") "Search status: no packages match")
    (expect-text (test-id "search-empty") "No packages match this search.")
    (expect-text (test-id "context") "Context: search results (0 matches)")
    (expect-visible (role region :name "Search results"))
    (expect-absent (role link :name "Open roc-json"))
    ; Failure path.
    (fill (label "Search packages") "boom")
    (stub-http-reject "search timeout" :kind timeout :detail "")
    (run-effect 5)
    (expect-pending-effects 0)
    (expect-text (test-id "search-status") "Search status: failed - Timeout")
    (expect-text (test-id "search-empty") "Search unavailable.")
    (expect-text (test-id "context") "Context: search results (0 matches)")
  )
)
