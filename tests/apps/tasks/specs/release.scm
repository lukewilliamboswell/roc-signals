(test "Tasks — the files a task's answer holds are released when the page lets go of them"
  (setup
    (file "notes.txt" "text/plain" "hello"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Upper"))
    (run-effect 1)
    (run-effect 2)
    (expect-files 2)
    (click (role button :name "Forget files"))
    (expect-files 0)
  )
)
