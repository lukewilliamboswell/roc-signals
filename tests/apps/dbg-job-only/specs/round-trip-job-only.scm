(test "a job-only debug observation leaves its ordinary answer unchanged"
  (steps
    (run-effect 1)
    (expect-text (test-id "answer") "job:0")
    (mark-metrics)
    (click (role button :name "Increment"))
    (run-effect 2)
    (expect-text (test-id "answer") "job:1")
    (click (role button :name "Reset"))
    (run-effect 3)
    (expect-text (test-id "answer") "job:0")
  )
)
