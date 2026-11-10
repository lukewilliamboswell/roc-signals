(test "Tasks — a cancelled job is never answered, and the next one is"
  (setup
    (file "notes.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Upper"))
    (expect-pending-effects 1)
    (click (role button :name "Stop"))
    (expect-pending-effects 0)
    (expect-text (test-id "outcome") "stopped")
    (expect-text (test-id "built") "none")
    (expect-files 1)
    (click (role button :name "Upper"))
    (run-effect 2)
    (expect-text (test-id "built") "notes.txt.upper:3:text/plain")
  )
)
