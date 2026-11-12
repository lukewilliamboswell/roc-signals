(test "Worker Lab — A strip larger than a job may write fails with its own error, and the picture is not composed"
  (setup
    (max-output-bytes 4000))
  (steps
    (select-option (label "Workload") "draw")
    (fill (label "Jobs") "1")
    (fill (label "Weight") "1")
    (click (role button :name "Start"))
    ; One strip of 128 by 85 pixels: its header fits under the bound, its
    ; pixels do not.
    (expect-visible (text "strip of 128 by 85 pixels, rows 1 to 85"))
    (run-effect 1)
    (expect-text (test-id "job-1") "failed: larger than a job may write")
    (expect-text (test-id "strip-1") "failed: larger than a job may write")
    (expect-text (test-id "stopped") "1")
    (expect-pending-effects 0)
    (expect-files 0)
  )
)
