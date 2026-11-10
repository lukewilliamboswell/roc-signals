(test "Tasks — convert a CSV in a worker, keep a log, measure a download, and save"
  (setup
    (file "sales.csv" "text/csv" "a,b\n1,2\n"))
  (steps
    (choose-files (label "CSV file") "sales.csv")
    (expect-text (test-id "converted") "converting")
    ; The conversion is a task's job: run-effect runs it in a worker.
    (run-effect 1)
    (expect-text (test-id "converted") "converted sales.csv.tsv (8 bytes)")
    (click (role button :name "Save TSV"))
    (expect-saved 1 "sales.csv.tsv" "a\tb\n1\t2\n")
    ; Each job appends to the log the last one built.
    (click (role button :name "Log a line"))
    (run-effect 2)
    (click (role button :name "Log a line"))
    (run-effect 3)
    (expect-text (test-id "log") "log: convert.log (16 bytes)")
    (click (role button :name "Save log"))
    (expect-saved 2 "convert.log" "entry 1\nentry 2\n")
    ; A download becomes a file, and a task measures it.
    (click (role button :name "Download data"))
    (stub-http "sales" :url "/data/sales.csv" :status 200 :headers (("content-type" "text/csv")) :body "x,y\n1,2\n3,4\n")
    (run-effect 4)
    (run-effect 5)
    (expect-text (test-id "downloaded") "3 lines downloaded")
  )
)
