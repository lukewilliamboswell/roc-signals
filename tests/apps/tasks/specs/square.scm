(test "Tasks — a task that calls no effect answers like any other"
  (steps
    (click (role button :name "Square"))
    (expect-pending-work "test.roc-signals/tasks/square" 1)
    (run-effect 1)
    (expect-text (test-id "outcome") "size 49")
  )
)
