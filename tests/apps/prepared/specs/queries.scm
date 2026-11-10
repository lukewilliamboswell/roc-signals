(test "Prepared — three typed queries over one prepared document answer as if each prepared afresh"
  (setup
    (file "doc.txt" "text/plain" "alpha beta gamma\nBeta alpha\n" 6000))
  (steps
    (expect-text (test-id "stats") "nothing")
    (choose-files (label "Document") "doc.txt")
    (expect-pending-work "test.roc-signals/prepared/stats" 1)
    (run-effect 1)
    (expect-text (test-id "stats") "12000 lines, 30000 words, 4 distinct")
    (click (role button :name "Top"))
    (expect-pending-work "test.roc-signals/prepared/top" 1)
    (run-effect 2)
    (expect-text (test-id "top") "alpha:12000 Beta:6000 beta:6000")
    (click (role button :name "Lookup"))
    (fill (label "Word") "gamma")
    ; The lookup for the empty word was superseded by the one for "gamma".
    (expect-pending-work "test.roc-signals/prepared/lookup" 1)
    (run-effect 4)
    (expect-text (test-id "lookup") "6000 at 1,3,5")
    (expect-pending-effects 0)
  )
)
