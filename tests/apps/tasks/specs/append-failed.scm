(test "Tasks — a job that fails leaves the log as it was"
  (steps
    (click (role button :name "Add batch"))
    (run-effect 1)
    (expect-text (test-id "log") "log.txt:8:text/plain")
    (click (role button :name "Add batch"))
    (lose-work 2 app_crash)
    (expect-text (test-id "outcome") "failed Lost(AppCrash)")
    (expect-text (test-id "log") "log.txt:8:text/plain")
    (expect-files 1)
    ; The next job starts from the log that was delivered.
    (click (role button :name "Add batch"))
    (run-effect 3)
    (click (role button :name "Save log"))
    (expect-saved 1 "log-copy.txt" "batch 1\nbatch 3\n")
  )
)
