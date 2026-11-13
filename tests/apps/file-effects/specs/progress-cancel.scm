(test "supersession stops a transfer after its preceding report"
  (setup (file "a.txt" "text/plain" "abcd"))
  (steps
    (choose-files (label "Upload") "a.txt")
    (click (role button :name "Send progress"))
    (mark-metrics)
    (hold-reports)
    (progress-effect 1 sending 1 4)
    (click (role button :name "Cancel progress"))
    (release-reports)
    (expect-pending-effects 0)
    (expect-metric-delta effects_cancelled 1)))
