(test "Field notes — two stored notes under one id restore as one"
  (setup
    (seed 7)
    (initial-online offline)
    ; A hand edit or another tab left two records under the id n0. The board
    ; draws notes keyed by id, so only the first is restored.
    (local-storage "field-notes:notes" "n0|0|1|r7|First copy;n0|1|0|r7|Second copy"))
  (steps
    (expect-value (label "Body n0") "First copy")
    (expect-text (test-id "outbox-count") "1")
  )
)
