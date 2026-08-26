(test "Log viewer — A query that matches nothing."
  (steps
    ; Given the state established by earlier scenarios
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (uncheck (label "Show debug"))
    (fill (label "Query") "timeout")

    ; A query that matches nothing.
    (fill (label "Query") "zzz-not-present")
    (expect-text (test-id "query-matches") "Query matches: 0")
    (expect-text (test-id "query-note") "No lines match the query.")
    (expect-text (test-id "match-line-3") "line-3 match: no")
    (expect-text (test-id "line-count") "Showing 3 of 4 lines")
  )
)
