(test "Tasks — a lost worker leaves nothing behind"
  (setup
    (file "three.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "three.txt")
    (click (role button :name "Upper"))
    (lose-work 1 executor)
    (expect-text (test-id "outcome") "failed Lost(Executor)")
    (expect-text (test-id "built") "none")
    (expect-files 1)
  )
)
