(test "Tasks — a new job supersedes the running one"
  (setup
    (file "notes.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Upper"))
    (click (role button :name "Crash"))
    ; Upper was cancelled when Crash was asked for.
    (expect-pending-work "test.roc-signals/tasks/upper" 0)
    (expect-pending-work "test.roc-signals/tasks/crash" 1)
    (run-effect 2)
    (expect-text (test-id "outcome") "failed Lost(AppCrash)")
    (expect-text (test-id "built") "none")
  )
)
