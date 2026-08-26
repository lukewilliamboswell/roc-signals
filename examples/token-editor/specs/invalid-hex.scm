(test "Token editor — invalid hex"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Text colour") "#777777")
    (fill (label "Text colour") "#767676")
    (fill (label "Accent colour") "#6f8ff0")
    (fill (label "Accent colour") "#2563eb")

    ; invalid hex
    (fill (label "Text colour") "#77zz77")
    (expect-text (test-id "token-validity") "Invalid tokens: color-fg")
    (expect-text (test-id "ratio-text") "n/a")
    (expect-text (test-id "aa-text") "AA fail")
    (expect-text (test-id "aa-button") "AA pass")
    (expect-text (test-id "aa-summary") "1 of 2 pairs pass AA")
    (expect-text (test-id "preview-surface") "color: /* invalid */; background: #ffffff; padding: 8px; font-size: 16px")
    (expect-text (test-id "stylesheet") ":root { --color-bg: #ffffff; --color-fg: /* invalid */; --color-accent: #2563eb; --space-sm: 8px; --font-md: 16px; --radius-md: 4px; }")
    ; A too-short hex is invalid the same way, and the app recovers from it.
    (fill (label "Text colour") "#777")
    (expect-text (test-id "token-validity") "Invalid tokens: color-fg")
    (expect-text (test-id "ratio-text") "n/a")
    (fill (label "Text colour") "#767676")
    (expect-text (test-id "token-validity") "All 6 tokens valid")
    (expect-text (test-id "ratio-text") "4.54:1")
  )
)
