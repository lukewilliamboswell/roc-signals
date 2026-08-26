(test "Token editor — one colour edit reaches every dependent binding, without rebuilding rows"
  (steps
    ; one colour edit reaches every dependent binding, without rebuilding rows
    (mark-metrics)
    (fill (label "Text colour") "#777777")
    (expect-text (test-id "preview-surface") "color: #777777; background: #ffffff; padding: 8px; font-size: 16px")
    (expect-text (test-id "preview-badge") "color: #ffffff; background: #777777; padding: 8px; font-size: 16px")
    (expect-text (test-id "preview-button") "color: #ffffff; background: #2563eb; padding: 8px; font-size: 16px")
    (expect-text (test-id "stylesheet") ":root { --color-bg: #ffffff; --color-fg: #777777; --color-accent: #2563eb; --space-sm: 8px; --font-md: 16px; --radius-md: 4px; }")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 3)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most dirty_source_roots 4)
    (expect-metric-delta-at-most patches_emitted 8)
  )
)
