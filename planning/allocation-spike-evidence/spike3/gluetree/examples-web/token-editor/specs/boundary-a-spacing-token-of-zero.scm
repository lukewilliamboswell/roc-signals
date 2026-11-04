(test "Token editor — boundary: a spacing token of zero"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Text colour") "#777777")
    (fill (label "Text colour") "#767676")
    (fill (label "Accent colour") "#6f8ff0")
    (fill (label "Accent colour") "#2563eb")
    (fill (label "Text colour") "#77zz77")
    (fill (label "Text colour") "#777")
    (fill (label "Text colour") "#767676")

    ; boundary: a spacing token of zero
    (fill (label "Spacing small") "0")
    (expect-text (test-id "token-validity") "All 6 tokens valid")
    (expect-attr (test-id "preview-surface") style "color: #767676; background: #ffffff; padding: 0px; font-size: 16px")
    (expect-attr (test-id "preview-button") style "color: #ffffff; background: #2563eb; padding: 0px; font-size: 16px")
    (expect-attr (test-id "preview-badge") style "color: #ffffff; background: #767676; padding: 0px; font-size: 16px")
    (expect-text (test-id "stylesheet") ":root { --color-bg: #ffffff; --color-fg: #767676; --color-accent: #2563eb; --space-sm: 0px; --font-md: 16px; --radius-md: 4px; }")
    ; Empty is not zero: it is an invalid size, and it does not disturb contrast.
    (fill (label "Spacing small") "")
    (expect-text (test-id "token-validity") "Invalid tokens: space-sm")
    (expect-attr (test-id "preview-surface") style "color: #767676; background: #ffffff; padding: /* invalid */; font-size: 16px")
    (expect-text (test-id "ratio-text") "4.54:1")
    (expect-text (test-id "aa-summary") "2 of 2 pairs pass AA")
    (fill (label "Spacing small") "8")
    (expect-text (test-id "token-validity") "All 6 tokens valid")
    (expect-attr (test-id "preview-surface") style "color: #767676; background: #ffffff; padding: 8px; font-size: 16px")
  )
)
