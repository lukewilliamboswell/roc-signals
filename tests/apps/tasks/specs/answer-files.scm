(test "Tasks — an answer holding more files than a job may return is a contract error of the job"
  (steps
    (click (role button :name "Many"))
    (run-effect 1)
    ; The worker refuses the answer itself: the job is lost, and none of
    ; its files reach the page.
    (expect-text (test-id "outcome") "failed Lost(Contract)")
    (expect-files 0)
  )
)
