(test "Prepared — a query cancelled under Stop and one cancelled under Finish both drop their answers"
  (setup
    (file "doc.txt" "text/plain" "alpha beta gamma\nBeta alpha\n" 600))
  (steps
    (choose-files (label "Document") "doc.txt")
    ; Stats stops a cancelled run; leaving its tab disposes its site.
    (mark-metrics)
    (click (role button :name "Top"))
    (expect-metric-delta effects_cancelled 1)
    (expect-pending-work "test.roc-signals/prepared/stats" 0)
    ; Top finishes a cancelled run instead; to the app it is cancelled all
    ; the same.
    (mark-metrics)
    (click (role button :name "Stats"))
    (expect-metric-delta effects_cancelled 1)
    (expect-pending-work "test.roc-signals/prepared/top" 0)
    (run-effect 3)
    (expect-text (test-id "stats") "1200 lines, 3000 words, 4 distinct")
    (expect-pending-effects 0)
  )
)
