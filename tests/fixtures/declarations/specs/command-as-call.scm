(test "Declaration refusal — command-as-call"
  (steps
    (expect-port-call 1 "command" "null")))
