(test "Tasks — an answer holding more files than a job may return is refused as TooManyFiles"
  (steps
    (click (role button :name "Many"))
    (run-effect 1)
    ; The worker refuses the answer itself: the result is TooManyFiles, the
    ; worker is kept, and none of its files reach the page.
    (expect-text (test-id "outcome") "failed TooManyFiles")
    (expect-files 0)
  )
)
