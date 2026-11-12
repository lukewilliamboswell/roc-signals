(test "Tasks — a cancelled job of a task that finishes is never answered, and the next one is"
  (setup
    (file "notes.txt" "text/plain" "a\nb\n"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Linger"))
    (expect-pending-effects 1)
    (click (role button :name "Stop"))
    (expect-pending-effects 0)
    (expect-text (test-id "outcome") "stopped")
    (click (role button :name "Linger"))
    (run-effect 2)
    (expect-text (test-id "outcome") "size 2")
  )
)
