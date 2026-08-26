(test "Query builder — edge case: empty leaf value"
  (steps
    ; edge case: empty leaf value
    (fill (label "Value n2") "")
    (expect-text (test-id "summary-n2") "ANY")
    (expect-text (test-id "query-text") "(ANY)")
    (expect-text (test-id "match-summary") "Matching rows: 5 of 5")
    (expect-visible (test-id "match-Cy"))
    (fill (label "Value n2") "Platform")
    (expect-text (test-id "match-summary") "Matching rows: 2 of 5")
  )
)
