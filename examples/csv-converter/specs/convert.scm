(test "CSV Converter — a dropped CSV is converted to TSV in a worker, previewed and saved"
  (setup
    (file "people.csv" "text/csv" "name,role\nAda,\"engineer, first\"\nGrace,admiral\n"))
  (steps
    (expect-text (test-id "status") "drop a CSV file, or load the sample")
    (drop-files (label "Drop a CSV file") "people.csv")
    (expect-text (test-id "source") "people.csv, 46 bytes")
    (expect-text (test-id "status") "converting…")
    (run-effect 1)
    (expect-text (test-id "status") "2 rows, 2 columns → people.tsv (44 bytes)")
    ; The preview is the output read back on the page.
    (run-effect 2)
    (expect-text (test-id "preview") "name\trole\nAda\tengineer, first\nGrace\tadmiral\n")
    (click (role button :name "Save"))
    (expect-saved 1 "people.tsv" "name\trole\nAda\tengineer, first\nGrace\tadmiral\n")
    ; The page holds the source and the output, nothing else.
    (expect-files 2)
  )
)
