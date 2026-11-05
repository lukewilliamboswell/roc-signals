(test "Markdown editor — Reading speed: a fan in of the counts and the selected words per minute"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (uncheck (label "Number the outline"))
    (check (label "Number the outline"))

    ; 3. Reading speed: a fan in of the counts and the selected words per minute
    ; Changing the speed must not touch the preview or the outline.
    ; ---------------------------------------------------------------------------

    (mark-metrics)
    (select-option (label "Reading speed") "100")
    (expect-value (label "Reading speed") "100")
    (expect-text (test-id "stat-reading") "2 min")
    (expect-text (test-id "stat-words") "147")
    (expect-text (test-id "stat-summary") "147 words | 822 characters | 5 headings | 2 min")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    ; Only the select value, the reading-time readout, and the summary change.
    (select-option (label "Reading speed") "300")
    (expect-text (test-id "stat-reading") "1 min")
    (select-option (label "Reading speed") "200")
    (expect-text (test-id "stat-reading") "1 min")
  )
)
