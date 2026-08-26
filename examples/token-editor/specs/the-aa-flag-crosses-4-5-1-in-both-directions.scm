(test "Token editor — the AA flag crosses 4.5:1 in both directions"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Text colour") "#777777")

    ; the AA flag crosses 4.5:1 in both directions
    ; #767676 on white is 4.54:1 (pass); #777777 on white is 4.47:1 (fail).
    (expect-text (test-id "ratio-text") "4.47:1")
    (expect-text (test-id "aa-text") "AA fail")
    (expect-text (test-id "aa-button") "AA pass")
    (expect-text (test-id "aa-summary") "1 of 2 pairs pass AA")
    (fill (label "Text colour") "#767676")
    (expect-text (test-id "ratio-text") "4.54:1")
    (expect-text (test-id "aa-text") "AA pass")
    (expect-text (test-id "aa-summary") "2 of 2 pairs pass AA")
  )
)
