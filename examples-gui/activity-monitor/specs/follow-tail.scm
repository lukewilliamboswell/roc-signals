(test "Follow-tail changes what is revealed, not how much work an append costs"
  (steps
    (click (role button :name "Step replay"))
    (click (role button :name "Step replay"))
    (expect-visible (test-id "event-2"))
    ; With follow-tail off, an append is still one new row and no existing row
    ; moves: not following is a viewport decision, not a rebuild.
    (uncheck (role checkbox :name "Follow latest"))
    (mark-metrics)
    (click (role button :name "Step replay"))
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_render_roots_moved 0)
    (expect-visible (test-id "event-3"))
    ; Turning follow-tail back on must not rebuild the feed to catch up.
    (mark-metrics)
    (check (role checkbox :name "Follow latest"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    ; And the next append costs exactly what it cost before.
    (mark-metrics)
    (click (role button :name "Step replay"))
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_render_roots_moved 0)
    (expect-visible (test-id "event-4"))))
