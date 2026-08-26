(test "Package explorer — E. keyed row budgets and per row edits"
  (setup
    ; A. deep link

    (initial-location "/packages/roc-json")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role link :name "Back to search"))
    (resolve-task "search" "roc-json|JSON codec for Roc;roc-http|HTTP client for Roc;roc-parser|Parser combinators for Roc")
    (fill (label "Search packages") "js")
    (fill (label "Search packages") "json")
    (mark-metrics)
    (resolve-stale-task "search" "stale-package|This superseded payload must never render")
    (resolve-task "search" "roc-json|JSON codec for Roc")
    (fill (label "Search packages") "zzzz")
    (resolve-task "search" "")
    (fill (label "Search packages") "boom")
    (reject-task "search" "registry unreachable")

    ; E. keyed row budgets and per row edits

    (fill (label "Search packages") "roc")
    (resolve-task "search" "roc-json|JSON codec for Roc;roc-http|HTTP client for Roc;roc-parser|Parser combinators for Roc")
    (expect-text (test-id "search-status") "Search status: 3 packages")
    (expect-text (test-id "order") "Order: A to Z")
    (expect-text (test-id "watch-roc-json") "roc-json: not watching")
    (expect-text (test-id "watch-roc-http") "roc-http: not watching")
    (expect-text (test-id "watch-roc-parser") "roc-parser: not watching")
    ; Reorder: the order toggle is client-side, so the same three row scopes are
    ; reused and nothing is created or removed.
    (mark-metrics)
    (check (label "Reverse order"))
    (expect-checked (label "Reverse order") true)
    (expect-text (test-id "order") "Order: Z to A")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 3)
    (expect-visible (role link :name "Open roc-parser"))
    (expect-visible (role link :name "Open roc-json"))
    (expect-visible (role link :name "Open roc-http"))
    (expect-text (test-id "summary-roc-json") "JSON codec for Roc")
    ; Per-row edit: watching one package must not recreate any row and must not
    ; disturb its siblings. One text patch is the whole cost.
    (mark-metrics)
    (click (role button :name "Watch roc-http"))
    (expect-text (test-id "watch-roc-http") "roc-http: watching")
    (expect-text (test-id "watch-roc-json") "roc-json: not watching")
    (expect-text (test-id "watch-roc-parser") "roc-parser: not watching")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta-at-most patches_emitted 1)
    ; Moving the watch to another row is symmetric.
    (click (role button :name "Watch roc-parser"))
    (expect-text (test-id "watch-roc-parser") "roc-parser: watching")
    (expect-text (test-id "watch-roc-http") "roc-http: not watching")
    (expect-text (test-id "watch-roc-json") "roc-json: not watching")
    (uncheck (label "Reverse order"))
    (expect-checked (label "Reverse order") false)
    (expect-text (test-id "order") "Order: A to Z")
    ; Add one package and remove another through a fresh search.
    (fill (label "Search packages") "roc core")
    (resolve-task "search" "roc-json|JSON codec for Roc;roc-parser|Parser combinators for Roc;roc-bytes|Byte helpers for Roc")
    (expect-text (test-id "search-status") "Search status: 3 packages")
    (expect-visible (role link :name "Open roc-bytes"))
    (expect-absent (role link :name "Open roc-http"))
    (expect-absent (test-id "summary-roc-http"))
    (expect-text (test-id "summary-roc-bytes") "Byte helpers for Roc")
    ; One row's summary changes while its siblings keep theirs.
    (fill (label "Search packages") "roc core ")
    (resolve-task "search" "roc-json|JSON codec for Roc, revised;roc-parser|Parser combinators for Roc;roc-bytes|Byte helpers for Roc")
    (expect-text (test-id "summary-roc-json") "JSON codec for Roc, revised")
    (expect-text (test-id "summary-roc-parser") "Parser combinators for Roc")
    (expect-text (test-id "summary-roc-bytes") "Byte helpers for Roc")
  )
)
