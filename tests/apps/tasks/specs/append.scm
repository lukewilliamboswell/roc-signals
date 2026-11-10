(test "Tasks — each job appends to the log the last job built, by starting from it"
  (steps
    (click (role button :name "Add batch"))
    (run-effect 1)
    (expect-text (test-id "log") "log.txt:8:text/plain")
    (click (role button :name "Add batch"))
    (run-effect 2)
    (expect-text (test-id "log") "log.txt:16:text/plain")
    (click (role button :name "Add batch"))
    (run-effect 3)
    (expect-text (test-id "log") "log.txt:24:text/plain")
    ; Each answer replaced the log, and the earlier ones were released.
    (expect-files 1)
    (click (role button :name "Save log"))
    (expect-saved 1 "log-copy.txt" "batch 1\nbatch 2\nbatch 3\n")
  )
)
