(test "Package explorer — C. the search page's own loading > loaded transition"
  (setup
    ; A. deep link

    (initial-location "/packages/roc-json")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role link :name "Back to search"))

    ; C. the search page's own loading > loaded transition

    (expect-visible (role region :name "Package search"))
    (expect-visible (role heading :name "Package search"))
    (expect-visible (role region :name "Search results"))
    (expect-value (label "Search packages") "")
    (expect-checked (label "Reverse order") false)
    (expect-text (test-id "search-status") "Search status: searching")
    (expect-text (test-id "search-empty") "Loading packages...")
    (expect-text (test-id "order") "Order: A to Z")
    (expect-text (test-id "context") "Context: search results (0 matches)")
    (expect-pending-task "search" 1)
    (resolve-task "search" "roc-json|JSON codec for Roc;roc-http|HTTP client for Roc;roc-parser|Parser combinators for Roc")
    (expect-pending-task "search" 0)
    (expect-text (test-id "search-status") "Search status: 3 packages")
    (expect-text (test-id "context") "Context: search results (3 matches)")
    (expect-absent (test-id "search-empty"))
    (expect-visible (role link :name "Open roc-json"))
    (expect-visible (role link :name "Open roc-http"))
    (expect-visible (role link :name "Open roc-parser"))
    (expect-text (test-id "summary-roc-json") "JSON codec for Roc")
    (expect-text (test-id "summary-roc-http") "HTTP client for Roc")
    (expect-text (test-id "summary-roc-parser") "Parser combinators for Roc")
    (expect-text (test-id "watch-roc-json") "roc-json: not watching")
  )
)
