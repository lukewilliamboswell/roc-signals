(test "Tasks — an answer holding more files than a job may return is refused"
  (steps
    (click (role button :name "Many"))
    (run-effect 1)
    (expect-text (test-id "outcome") "failed FileFailed(TooLarge)")
    (expect-files 0)
  )
)
