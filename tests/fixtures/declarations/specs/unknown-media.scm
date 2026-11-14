(test "Declaration refusal — unknown-media"
  (steps
    (expect-media-subscriptions "misspelt-query" 0)))
