(test "Tasks — a job whose deadline expires is answered Timeout"
  (setup
    (file "three.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "three.txt")
    (click (role button :name "Timed"))
    (time-out-work 1)
    (expect-text (test-id "outcome") "failed Timeout")
    (expect-files 1)
    ; A job with a deadline that finishes in time answers.
    (click (role button :name "Stop"))
    (click (role button :name "Timed"))
    (run-effect 2)
    (expect-text (test-id "outcome") "size 3")
  )
)
