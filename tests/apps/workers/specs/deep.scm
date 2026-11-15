(test "Workers — an answer nested past the payload bound is a typed TooDeep, and the worker goes on answering"
  (steps
    (click (role button :name "Deep"))
    (expect-pending-effects 1)
    ; The answer would nest 600 containers, more than the 128 a payload may.
    ; The worker answers the one flag byte TooDeep instead: nothing of the
    ; value is sent, the job is not lost, and the page never decodes it.
    (run-effect 1)
    (expect-text (test-id "log") "deep:too deep")
    (expect-pending-effects 0)
    ; The worker was kept: the next job answers, and asking again is
    ; refused the same way rather than poisoning anything.
    (click (role button :name "Upper"))
    (run-effect 2)
    (expect-text (test-id "log") "deep:too deep|upper:JOB 1")
    (click (role button :name "Deep"))
    (run-effect 3)
    (expect-text (test-id "log") "deep:too deep|upper:JOB 1|deep:too deep")
    (expect-pending-effects 0)
  )
)
