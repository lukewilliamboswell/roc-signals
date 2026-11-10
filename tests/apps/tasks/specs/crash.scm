(test "Tasks — a job that crashes is lost, and leaves no file"
  (setup
    (file "three.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "three.txt")
    (click (role button :name "Crash"))
    (run-effect 1)
    (expect-text (test-id "outcome") "failed Lost(AppCrash)")
    (expect-files 1)
  )
)
