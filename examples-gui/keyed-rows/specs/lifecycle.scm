(test "GUI row drafts survive moves and reset on disposal"
  (steps
    (fill (label "Draft Alpha") "kept draft")
    (expect-value (label "Draft Alpha") "kept draft")
    ; A move reorders render roots. Every row keeps its scope, so no row is
    ; created, removed or rebuilt: exactly one render root changes position.
    (mark-metrics)
    (click (role button :name "Move first to end"))
    (expect-metric-delta rows_reused 3)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_render_roots_moved 1)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-value (label "Draft Alpha") "kept draft")
    ; Hiding the list disposes the branch that owns the rows: the three row
    ; scopes and the branch scope itself. The one scope created is the empty
    ; branch that replaces them, not a row surviving its own disposal.
    (mark-metrics)
    (click (role button :name "Hide / show rows"))
    (expect-visible (text "Rows disposed"))
    (expect-metric-delta scopes_disposed 4)
    (expect-metric-delta scopes_created 1)
    ; Showing them again builds fresh scopes — the branch and its three rows —
    ; and disposes the empty branch, which is why the draft a person typed is
    ; gone rather than restored from a retained row.
    (mark-metrics)
    (click (role button :name "Hide / show rows"))
    (expect-metric-delta scopes_created 4)
    (expect-metric-delta scopes_disposed 1)
    (expect-value (label "Draft Alpha") "")))
