(test "Workers — an answer nested too deep for the page is refused in the worker, and the page keeps working"
  (steps
    (click (role button :name "Deep"))
    (expect-pending-effects 1)
    ; The answer would nest 601 containers, more than a payload may. The
    ; worker refuses to send it, a contract fault of that worker instance
    ; alone, so the page never decodes it.
    (run-effect 1)
    (expect-text (test-id "log") "deep:lost Contract")
    (click (role button :name "Upper"))
    (run-effect 2)
    (expect-text (test-id "log") "deep:lost Contract|upper:JOB 1")
  )
)
