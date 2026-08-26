(test "Log viewer — Filters and query fan in to one visible set: the debug row is the only"
  (steps
    ; Given the state established by earlier scenarios
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (uncheck (label "Show debug"))
    (fill (label "Query") "timeout")
    (fill (label "Query") "zzz-not-present")

    ; Filters and query fan in to one visible set: the debug row is the only
    ; match, so hiding debug flips the query result to empty.
    (check (label "Show debug"))
    (fill (label "Query") "debug")
    (expect-text (test-id "line-count") "Showing 4 of 4 lines")
    (expect-text (test-id "query-matches") "Query matches: 1")
    (expect-text (test-id "match-line-4") "line-4 match: yes")
    (expect-text (test-id "query-note") "Query filter idle.")
    (uncheck (label "Show debug"))
    (expect-text (test-id "line-count") "Showing 3 of 4 lines")
    (expect-text (test-id "query-matches") "Query matches: 0")
    (expect-text (test-id "query-note") "No lines match the query.")
  )
)
