(test "Tasks — a job reads back a file it built, through the file's own methods"
  (setup
    (file "notes.txt" "text/plain" "hello"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Reread"))
    (expect-pending-work "test.roc-signals/tasks/reread" 1)
    (run-effect 1)
    (expect-text (test-id "outcome") "reread hello!")
  )
)
