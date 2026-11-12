(test "CSV Converter — the sample is downloaded into a file and converted like a dropped one"
  (steps
    (click (role button :name "Load the sample"))
    (stub-http "sample" :url "sample.csv" :status 200 :headers (("content-type" "text/csv")) :body "city,country\nTokyo,Japan\n")
    (run-effect 1)
    (expect-text (test-id "source") "sample.csv, 25 bytes")
    (run-effect 2)
    (expect-text (test-id "status") "1 rows, 2 columns → sample.tsv (25 bytes)")
  )
)
