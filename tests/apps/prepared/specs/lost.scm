(test "Prepared — a lost worker loses only its query, and the next one prepares again"
  (setup
    (file "doc.txt" "text/plain" "alpha beta gamma\nBeta alpha\n" 600))
  (steps
    (choose-files (label "Document") "doc.txt")
    (lose-work 1 app_crash)
    (expect-text (test-id "stats") "lost AppCrash")
    (click (role button :name "Top"))
    (run-effect 2)
    (expect-text (test-id "top") "alpha:1200 Beta:600 beta:600")
  )
)
