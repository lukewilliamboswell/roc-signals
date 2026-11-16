(test "Tasks — an answer holding 16 files is delivered, one holding 17 is refused as TooManyFiles, and the next job answers"
  (steps
    (click (role button :name "Sixteen"))
    (run-effect 1)
    ; As many files as an answer may hold: all of them reach the page, which
    ; counts them and lets them go.
    (expect-text (test-id "outcome") "files 16")
    (expect-files 0)
    (click (role button :name "Many"))
    (run-effect 2)
    ; One more: the worker refuses the answer itself. The result is
    ; TooManyFiles, the worker is kept, and none of its files reach the page.
    (expect-text (test-id "outcome") "failed TooManyFiles")
    (expect-files 0)
    (click (role button :name "Few"))
    (run-effect 3)
    (expect-text (test-id "outcome") "files 3")
    (expect-files 0)
  )
)
