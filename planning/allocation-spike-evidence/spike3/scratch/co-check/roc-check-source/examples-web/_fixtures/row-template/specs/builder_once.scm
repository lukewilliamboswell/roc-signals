(test "Row template builder runs once per site"
  (steps
    ; Three sites mount with three rows each. Each site's rows share one subtree,
    ; so the subtree changes once per site, not once per row.
    (expect-text (test-id "first-c") "c<c>static")
    (mark-metrics)
    (click (role button :name "Toggle"))
    (click (role button :name "Toggle"))
    (expect-metric-delta row_template_instances 3)
    (expect-metric-delta row_template_subtrees 1)))
