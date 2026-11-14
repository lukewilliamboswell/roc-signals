(test "Declaration refusal — unknown-local"
  (steps
    (expect-no-local-storage "misspelt-local")))
