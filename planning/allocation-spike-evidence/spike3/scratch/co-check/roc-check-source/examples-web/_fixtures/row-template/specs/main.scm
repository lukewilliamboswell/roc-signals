(test "Row template"
  (steps
    ; Keys reach text and attributes exactly, with literal text around them.
    (expect-text (test-id "first-a") "a<a>static")
    (expect-attr (test-id "first-a") data-key "a")
    (expect-visible (role link :name "Open first a now"))
    (expect-visible (role link :name "Open ordinary a now"))

    ; Two sites declared alike stay independent, and match an ordinary site.
    (expect-text (test-id "second-c") "c<c>static")
    (expect-text (test-id "ordinary-c") "c<c>static")
    (expect-attr (test-id "ordinary-c") data-key "c")

    ; Appending instantiates only the new rows at each of the three sites.
    (mark-metrics)
    (click (role button :name "Append"))
    (expect-text (test-id "first-e") "e<e>static")
    (expect-text (test-id "nested-d") "d<d>static")
    (expect-metric-delta row_template_instances 6)
    (expect-metric-delta rows_created 8)
    (expect-metric-delta rows_removed 0)

    ; A reorder moves rendered rows. It rebuilds no template instance and
    ; preserves every row scope.
    (mark-metrics)
    (click (role button :name "Reorder"))
    (expect-metric-delta row_template_instances 0)
    (expect-metric-delta row_template_subtrees 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)

    ; A removal disposes that row's scope at every site.
    (mark-metrics)
    (click (role button :name "Remove"))
    (expect-absent (test-id "first-b"))
    (expect-absent (test-id "second-b"))
    (expect-absent (test-id "nested-b"))
    (expect-visible (test-id "ordinary-a"))
    (expect-metric-delta row_template_instances 0)
    (expect-metric-delta rows_removed 4)
    (expect-metric-delta scopes_disposed 4)

    ; Disposing a template site releases every row and its template owner, and
    ; remounting returns to exactly the same retained footprint.
    (click (role button :name "Toggle"))
    (expect-absent (test-id "nested-a"))
    (click (role button :name "Toggle"))
    (expect-text (test-id "nested-a") "a<a>static")
    (mark-metrics)
    (click (role button :name "Toggle"))
    (click (role button :name "Toggle"))
    (expect-text (test-id "nested-a") "a<a>static")
    (expect-metric-delta row_template_instances 4)
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta closure_retains 87)
    (expect-metric-delta closure_releases 87)))
