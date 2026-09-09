(test "Package explorer — D. latest wins search and a stale result"
  (setup
    ; A. deep link

    (initial-location "/packages/roc-json")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role link :name "Back to search"))
    (resolve-task "search" "roc-json|JSON codec for Roc;roc-http|HTTP client for Roc;roc-parser|Parser combinators for Roc")

    ; D. latest wins search and a stale result

    (fill (label "Search packages") "js")
    (expect-value (label "Search packages") "js")
    (expect-pending-task "search" 1)
    (expect-text (test-id "search-status") "Search status: searching")
    (expect-canceled-task "search" 0)
    ; Typing again supersedes the first request: the old one is cancelled and only
    ; the newest may land.
    (fill (label "Search packages") "json")
    (expect-pending-task "search" 1)
    (expect-canceled-task "search" 1)
    (mark-metrics)
    (resolve-stale-task "search" "stale-package|This superseded payload must never render")
    (expect-metric-delta stale_task_results_ignored 1)
    (expect-text (test-id "search-status") "Search status: searching")
    (expect-absent (role link :name "Open stale-package"))
    (expect-pending-task "search" 1)
    ; One matching package: the singular boundary case.
    (resolve-task "search" "roc-json|JSON codec for Roc")
    (expect-pending-task "search" 0)
    (expect-text (test-id "search-status") "Search status: 1 package")
    (expect-text (test-id "context") "Context: search results (1 matches)")
    (expect-visible (role link :name "Open roc-json"))
    (expect-absent (role link :name "Open roc-http"))
    ; No matches: the empty branch of the list.
    (fill (label "Search packages") "zzzz")
    (expect-pending-task "search" 1)
    (resolve-task "search" "")
    (expect-text (test-id "search-status") "Search status: no packages match")
    (expect-text (test-id "search-empty") "No packages match this search.")
    (expect-text (test-id "context") "Context: search results (0 matches)")
    (expect-visible (role region :name "Search results"))
    (expect-absent (role link :name "Open roc-json"))
    ; Failure path.
    (fill (label "Search packages") "boom")
    (reject-task "search" "registry unreachable")
    (expect-pending-task "search" 0)
    (expect-text (test-id "search-status") "Search status: failed - registry unreachable")
    (expect-text (test-id "search-empty") "Search unavailable.")
    (expect-text (test-id "context") "Context: search results (0 matches)")
  )
)
