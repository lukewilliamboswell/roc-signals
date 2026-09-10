(test "Selection recomputes the rows that changed and repeating it does nothing"
  (steps
    ; Selection moves between two rows. Only those two rows' membership
    ; changes, so the third row's derived value is not recomputed and no row
    ; or scope is built or torn down to show the change.
    (mark-metrics)
    (click (role button :name "Select Beta"))
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    ; Selecting the row that is already selected is an equality no-op: the
    ; source is written, the propagation is pruned, and nothing derives.
    (mark-metrics)
    (click (role button :name "Select Beta"))
    (expect-metric-delta propagation_prunes 1)
    (expect-metric-delta derived_calls_into_roc 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta scopes_created 0)
    ; The same rule holds for an editor echoing the value it already holds,
    ; which is the case a controlled input has to leave alone.
    (fill (label "Draft Beta") "kept")
    (mark-metrics)
    (fill (label "Draft Beta") "kept")
    (expect-metric-delta propagation_prunes 1)
    (expect-metric-delta derived_calls_into_roc 0)
    (expect-value (label "Draft Beta") "kept")))
