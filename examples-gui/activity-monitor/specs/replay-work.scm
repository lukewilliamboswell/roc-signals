(test "Appending, filtering and following an activity feed each do their own work"
  (steps
    (click (role button :name "Step replay"))
    (click (role button :name "Step replay"))
    (click (role button :name "Step replay"))
    (expect-visible (text "Retained: 3 / 1000"))
    ; Appending one event is changed-set work: one row arrives, nothing else
    ; is rebuilt, and no existing row changes position.
    (mark-metrics)
    (click (role button :name "Step replay"))
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_render_roots_moved 0)
    (expect-metric-delta scopes_disposed 0)
    ; Filtering is whole-dataset work: the events that stop matching leave and
    ; their scopes are disposed with them, while a matching event keeps its row.
    (mark-metrics)
    (fill (role textbox :name "Filter activity") "Indexer")
    (expect-metric-delta rows_removed 3)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 1)
    (expect-metric-delta scopes_disposed 3)
    ; Re-entering the same filter is an equality no-op: the source is written
    ; and the propagation is pruned before any row is reconsidered.
    (mark-metrics)
    (fill (role textbox :name "Filter activity") "Indexer")
    (expect-metric-delta propagation_prunes 1)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    ; An event that does not match the active filter appends no row at all;
    ; the filter boundary is evaluated for the changed event, not the feed.
    (mark-metrics)
    (click (role button :name "Step replay"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_render_roots_moved 0)
    (expect-visible (text "Retained: 5 / 1000"))))
