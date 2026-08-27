(test "Token editor — radius md appears only in the stylesheet, so editing it must not touch the"
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
    (fill (label "Spacing small") "0")
    (fill (label "Spacing small") "")
    (fill (label "Spacing small") "8")

    ; radius md appears only in the stylesheet, so editing it must not touch the
    ; preview list or the contrast graph at all.
    (mark-metrics)
    (fill (label "Corner radius medium") "12")
    (expect-text (test-id "stylesheet") ":root { --color-bg: #ffffff; --color-fg: #767676; --color-accent: #2563eb; --space-sm: 8px; --font-md: 16px; --radius-md: 12px; }")
    (expect-attr (test-id "preview-surface") style "color: #767676; background: #ffffff; padding: 8px; font-size: 16px")
    (expect-text (test-id "ratio-text") "4.54:1")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    ; Two more patches than before: the radius token row now draws a to-scale
    ; size bar and a resolved "12px" caption, both fed by the same signal.
    (expect-metric-delta-at-most patches_emitted 4)
    (fill (label "Corner radius medium") "abc")
    (expect-text (test-id "token-validity") "Invalid tokens: radius-md")
    (expect-text (test-id "stylesheet") ":root { --color-bg: #ffffff; --color-fg: #767676; --color-accent: #2563eb; --space-sm: 8px; --font-md: 16px; --radius-md: /* invalid */; }")
    (expect-text (test-id "aa-summary") "2 of 2 pairs pass AA")
    (fill (label "Corner radius medium") "4")
    (expect-text (test-id "token-validity") "All 6 tokens valid")
  )
)
