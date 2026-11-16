(test "Declaration refusal — unknown-session"
  (steps
    (expect-no-session-storage "misspelt-session")))
