(test "Tasks — a file a task built is saved as a download, under its own name or another"
  (setup
    (file "notes.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Upper"))
    (run-effect 1)
    (expect-saves 0)
    (click (role button :name "Save"))
    (expect-saves 1)
    (expect-saved 1 "notes.txt.upper" "ABC")
    ; Saving again saves again.
    (click (role button :name "Save"))
    (expect-saved 2 "notes.txt.upper" "ABC")
  )
)
