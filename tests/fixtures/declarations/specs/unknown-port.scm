(test "Declaration refusal — unknown-port"
  (steps
    (expect-port-sends "misspelt-port" 0)))
