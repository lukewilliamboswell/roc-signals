(test "Selection is changed-set work while filtering and sorting are whole-dataset work"
  (steps
    (click (role button :name "README.md"))
    (expect-visible (text "Size: 1536 B"))
    ; Selecting another file changes which entry is selected and what the
    ; inspector shows. It must not touch the list itself: no row is created,
    ; removed or rebuilt, and no scope is built or torn down. The inspector's
    ; own recomputation is bounded rather than pinned, because it is incidental
    ; work whose exact shape is not a promise this example makes.
    (mark-metrics)
    (click (role button :name "release-notes.md"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most derived_calls_into_roc 32)
    (expect-visible (text "Size: 0 B"))
    ; Sorting is whole-dataset work by construction: every entry is compared.
    ; What must survive it is identity — the six rows are reused, not rebuilt,
    ; so a row's scope and anything it owns outlive the reordering.
    (mark-metrics)
    (click (role button :name "Name Z–A"))
    (expect-metric-delta rows_reused 6)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    ; Filtering is the other whole-dataset path, and here the result really is
    ; a smaller set: five rows leave and their scopes are disposed with them.
    (mark-metrics)
    (fill (role textbox :name "Filter this folder") "release")
    (expect-metric-delta rows_removed 5)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 1)
    (expect-metric-delta scopes_disposed 10)
    (expect-visible (text "1 matching entries"))
    ; The selection the filter hid is still the selection: the inspector keeps
    ; showing it, so restoring the list restores the row rather than rebuilding
    ; a new one for the same key.
    (expect-visible (text "Size: 0 B"))
    (mark-metrics)
    (click (role button :name "Clear filter"))
    (expect-metric-delta rows_created 5)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 1)
    (expect-visible (text "6 matching entries"))))
