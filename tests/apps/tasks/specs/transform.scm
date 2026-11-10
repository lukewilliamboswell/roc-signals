(test "Tasks — a task reads a file in chunks through effects and answers with a file it built"
  (setup
    (file "notes.txt" "text/plain" "hello, tasks!"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (expect-files 1)
    (click (role button :name "Upper"))
    (expect-text (test-id "outcome") "running")
    (expect-pending-work "test.roc-signals/tasks/upper" 1)
    (run-effect 1)
    (expect-text (test-id "outcome") "built notes.txt.upper:13:text/plain")
    (expect-text (test-id "built") "notes.txt.upper:13:text/plain")
    ; The page holds the built file as a handle of its own.
    (expect-files 2)
    ; It is a file like any other: the page reads it back.
    (run-effect 2)
    (expect-text (test-id "preview") "HELLO, TASKS!")
  )
)
