(test "Declaration refusal — unknown-task"
  (steps
    (expect-pending-work "misspelt-task" 0)))
