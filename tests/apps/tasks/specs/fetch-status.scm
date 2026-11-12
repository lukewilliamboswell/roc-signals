(test "Tasks — a download that fails, or answers outside 2xx, gives no file"
  (steps
    (click (role button :name "Fetch"))
    (stub-http "missing" :url "/data.csv" :status 404 :headers (("content-type" "text/plain")) :body "no such file")
    (run-effect 1)
    (expect-text (test-id "outcome") "fetch failed Status(404)")
    (expect-files 0)
  )
)
