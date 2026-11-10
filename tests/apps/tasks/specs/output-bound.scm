(test "Tasks — a builder over the job's output bound fails with a typed error, and nothing is delivered"
  (setup
    (max-output-bytes 8)
    (file "three.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "three.txt")
    (click (role button :name "Overflow"))
    (run-effect 1)
    ; 3 + 3 bytes fit; the third append would make 9.
    (expect-text (test-id "outcome") "error TooLarge")
    (expect-text (test-id "built") "none")
    (expect-files 1)
  )
)
