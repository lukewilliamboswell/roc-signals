(test "Prepared — a tab's task site asks again on every visit"
  (setup
    (file "doc.txt" "text/plain" "alpha beta gamma\nBeta alpha\n" 600))
  (steps
    (choose-files (label "Document") "doc.txt")
    (run-effect 1)
    (expect-text (test-id "stats") "1200 lines, 3000 words, 4 distinct")
    (click (role button :name "Top"))
    (run-effect 2)
    (click (role button :name "Stats"))
    (expect-pending-work "test.roc-signals/prepared/stats" 1)
    (expect-text (test-id "stats") "working")
    (run-effect 3)
    (expect-text (test-id "stats") "1200 lines, 3000 words, 4 distinct")
  )
)
