(test "Workers — a job lost with a fault class reaches its reaction as WorkLost"
  (steps
    (click (role button :name "Batch"))
    (click (role button :name "Upper"))
    (expect-pending-work "test.roc-signals/upper" 5)
    ; Answered lost without running: the class reaches the app as it is.
    (lose-work 2 out_of_memory)
    (lose-work 5 unavailable)
    (lose-work 1 executor)
    (expect-pending-work "test.roc-signals/upper" 2)
    (run-effect 3)
    (lose-work 4 resource_limit)
    (expect-pending-effects 0)
    (expect-text (test-id "log") "batch:lost OutOfMemory|upper:lost Unavailable|batch:lost Executor|batch:B1-3|batch:lost ResourceLimit")
  )
)
