(test "Tasks — finishing a builder twice is a contract error of the job"
  (steps
    (click (role button :name "Twice"))
    (run-effect 1)
    (expect-text (test-id "outcome") "failed Lost(Contract)")
    (expect-files 0)
  )
)
