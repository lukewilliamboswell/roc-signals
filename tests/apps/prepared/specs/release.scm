(test "Prepared — forgetting the document releases its file, and no task is asked"
  (setup
    (file "doc.txt" "text/plain" "alpha beta gamma\nBeta alpha\n" 600))
  (steps
    (choose-files (label "Document") "doc.txt")
    (run-effect 1)
    (expect-files 1)
    (click (role button :name "Forget"))
    (expect-files 0)
    (expect-text (test-id "stats") "nothing")
    (expect-pending-effects 0)
  )
)
