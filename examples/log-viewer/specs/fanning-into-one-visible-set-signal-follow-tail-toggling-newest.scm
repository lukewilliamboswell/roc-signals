(test "Log viewer — fanning into one visible set signal, follow tail toggling, newest first"
  (steps
    ; fanning into one visible set signal, follow tail toggling, newest first
    ; reordering, clearing, and tail-only update granularity for a long buffer.

    (expect-visible (role heading :name "Log Viewer"))
    (expect-visible (role region :name "Log controls"))
    (expect-visible (role region :name "Log stream"))
    (expect-checked (label "Show debug") true)
    (expect-checked (label "Show info") true)
    (expect-checked (label "Show warn") true)
    (expect-checked (label "Show error") true)
    (expect-checked (label "Follow tail") true)
    (expect-checked (label "Newest first") false)
    (expect-text (test-id "order-mode") "Order: oldest first")
    (expect-value (label "Query") "")
    (expect-text (test-id "line-count") "Showing 0 of 0 lines")
    (expect-text (test-id "query-matches") "Query matches: 0")
    (expect-text (test-id "query-note") "Query filter idle.")
    (expect-visible (role region :name "Tail"))
    (expect-text (test-id "tail-line") "Tail: waiting for the first line")
    (expect-visible (role region :name "Log empty"))
    (expect-visible (text "Log buffer is empty"))
    (expect-absent (role region :name "Log lines"))
    (expect-interval 1000 1)
    (expect-cleanup "log stream cleanup" 0)
  )
)
