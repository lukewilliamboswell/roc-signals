(test "Log viewer — Query highlights matches inside the level-filtered set."
  (steps
    ; Given the state established by earlier scenarios
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (uncheck (label "Show debug"))

    ; Query highlights matches inside the level-filtered set.
    (fill (label "Query") "timeout")
    (expect-value (label "Query") "timeout")
    (expect-text (test-id "query-matches") "Query matches: 1")
    (expect-attr (test-id "match-line-3") data-match "yes")
    (expect-attr (test-id "match-line-1") data-match "no")
    (expect-text (test-id "query-note") "Query filter idle.")
  )
)
