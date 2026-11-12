(test "Prepared — a task's timeout covers its preparation"
  (setup
    (file "doc.txt" "text/plain" "alpha beta gamma\nBeta alpha\n" 600))
  (steps
    (choose-files (label "Document") "doc.txt")
    (click (role button :name "Lookup"))
    (fill (label "Word") "beta")
    (mark-metrics)
    (time-out-work 3)
    (expect-metric-delta effects_delivered 1)
    (expect-text (test-id "lookup") "timed out")
    (fill (label "Word") "alpha")
    (run-effect 4)
    (expect-text (test-id "lookup") "1200 at 1,2,3")
  )
)
