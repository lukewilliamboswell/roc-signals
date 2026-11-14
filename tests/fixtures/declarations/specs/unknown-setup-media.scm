(test "Declaration refusal — setup query"
  (setup
    (initial-media "misspelt-query" true))
  (steps (mark-metrics)))
