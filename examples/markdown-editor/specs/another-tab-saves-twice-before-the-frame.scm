(test "Markdown editor — another tab saves twice before the frame"
  (setup (local-storage "md.document" "# Before"))
  (steps
    (hold-reports)
    (mark-metrics)
    (storage-elsewhere "md.document" "# First")
    (storage-elsewhere "md.document" "# Second")
    (expect-value (label "Markdown source") "# Before")
    (expect-reports-replaced 1)
    (release-reports)
    (expect-value (label "Markdown source") "# Second")
    (expect-metric-delta effects_delivered 1)
    (expect-session-storage "md.draft" "# Second"))
)
