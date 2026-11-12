(test "Workers — a job's output arrives as one effect-result turn and renders"
  (steps
    (click (role button :name "Upper"))
    (expect-pending-effects 1)
    (expect-text (test-id "log") "")
    (mark-metrics)
    (run-effect 1)
    (expect-pending-effects 0)
    ; The result is one turn that writes the log: one text write.
    (expect-text (test-id "log") "upper:JOB 1")
    (expect-metric-delta set_text 1)
    (expect-metric-delta create_element 0)
  )
)
