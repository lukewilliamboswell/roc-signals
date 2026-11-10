(test "Tasks — a task reads a file in chunks through effects and answers with a file it built"
  (setup
    (file "notes.txt" "text/plain" "hello, tasks!"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Upper"))
    (expect-text (test-id "upper") "running")
    (expect-pending-work "test.roc-signals/tasks/upper" 1)
    (run-effect 1)
    (expect-text (test-id "upper") "built notes.txt.upper:13")
  )
)
