(test "CSV Converter — changing the format converts again, and stops the job for the old one"
  (setup
    (file "people.csv" "text/csv" "name,age\nAda,36\nAlan\n"))
  (steps
    (choose-files (label "CSV file") "people.csv")
    (select-option (label "Format") "jsonl")
    ; The TSV job was stopped when the format changed.
    (expect-pending-work "roc-signals.example/csv-converter/convert" 1)
    (run-effect 2)
    (expect-text (test-id "status") "2 rows, 2 columns (1 with another number of fields) → people.jsonl (51 bytes)")
    (run-effect 3)
    (expect-text (test-id "preview") "{\"name\":\"Ada\",\"age\":\"36\"}\n{\"name\":\"Alan\",\"age\":\"\"}\n")
    (click (role button :name "Save"))
    (expect-saved 1 "people.jsonl" "{\"name\":\"Ada\",\"age\":\"36\"}\n{\"name\":\"Alan\",\"age\":\"\"}\n")
  )
)
