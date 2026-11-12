(test "CSV Converter — a conversion that fails says why, and an empty file has nothing to convert"
  (setup
    (file "empty.csv" "text/csv" "")
    (file "big.csv" "text/csv" "a,b\n1,2\n"))
  (steps
    (choose-files (label "CSV file") "empty.csv")
    (run-effect 1)
    (expect-text (test-id "status") "could not convert: the file is empty")
    (choose-files (label "CSV file") "big.csv")
    (lose-work 2 out_of_memory)
    (expect-text (test-id "status") "the conversion stopped: Lost(OutOfMemory)")
    (expect-files 1)
  )
)
