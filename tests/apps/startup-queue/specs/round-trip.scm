(test "waiting queue readiness round trip creates no scopes or DOM"
  (setup (initial-location "/queue-large/"))
  (steps
    (expect-text (role button :name "Toggle") "Toggle")
    (mark-metrics)
    (click (role button :name "Toggle"))
    (click (role button :name "Toggle"))
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta create_element 0)
    (expect-metric-delta set_text 0)
    (expect-text (role button :name "Toggle") "Toggle")))
