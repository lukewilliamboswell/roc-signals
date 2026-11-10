(test "Workers — a task that crashes loses its job, and the page keeps working"
  (steps
    (click (role button :name "Crash"))
    (expect-pending-effects 1)
    ; The task crashes in an instance of its own: in Chrome a Web Worker,
    ; natively a child process of the runner. The job is lost with the
    ; crash's fault class, and nothing else is.
    (run-effect 1)
    (expect-text (test-id "log") "crash:lost AppCrash")
    (click (role button :name "Upper"))
    (run-effect 2)
    (expect-text (test-id "log") "crash:lost AppCrash|upper:JOB 1")
  )
)
