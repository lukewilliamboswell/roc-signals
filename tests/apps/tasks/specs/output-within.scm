(test "Tasks — within its bound a job copies bytes into its builder"
  (setup
    (max-output-bytes 9)
    (file "three.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "three.txt")
    (click (role button :name "Overflow"))
    (run-effect 1)
    (expect-text (test-id "outcome") "built copies.txt:9:")
    (expect-files 2)
  )
)
