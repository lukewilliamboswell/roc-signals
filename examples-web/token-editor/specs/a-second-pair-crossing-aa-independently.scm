(test "Token editor — a second pair crossing AA independently"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Text colour") "#777777")
    (fill (label "Text colour") "#767676")

    ; a second pair crossing AA independently
    (fill (label "Accent colour") "#6f8ff0")
    (expect-text (test-id "ratio-button") "3.05:1")
    (expect-text (test-id "aa-button") "Fail")
    (expect-text (test-id "aa-text") "AA")
    (expect-text (test-id "aa-summary") "1 of 2 pairs pass AA")
    (expect-attr (test-id "preview-button") style "color: #ffffff; background: #6f8ff0; padding: 8px; font-size: 16px")
    (fill (label "Accent colour") "#2563eb")
    (expect-text (test-id "ratio-button") "5.16:1")
    (expect-text (test-id "aa-button") "AA")
    (expect-text (test-id "aa-summary") "2 of 2 pairs pass AA")
  )
)
