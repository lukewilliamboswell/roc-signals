(test "Tasks — a download becomes a file the page holds, and a task reads it"
  (steps
    (click (role button :name "Fetch"))
    (expect-pending-effects 1)
    (stub-http "data" :url "/data.csv" :status 200 :headers (("content-type" "text/csv")) :body "a,b\n1,2\n3,4\n")
    (run-effect 1)
    (expect-text (test-id "fetched") "data.csv:12:text/csv")
    (expect-files 1)
    (click (role button :name "Count lines"))
    (run-effect 2)
    (expect-text (test-id "outcome") "lines 3")
  )
)
