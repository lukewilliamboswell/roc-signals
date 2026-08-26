(test "Markdown editor — Numbering toggle: a fan-in of the heading spine and a boolean."
  (steps
    ; 2. Numbering toggle: a fan-in of the heading spine and a boolean.
    ; Row identity is the heading slug, so toggling relabels rows in place.
    ; ---------------------------------------------------------------------------

    (mark-metrics)
    (uncheck (label "Number the outline"))
    (expect-checked (label "Number the outline") false)
    (expect-absent (text "1. Roc Signals Field Guide"))
    (expect-absent (text "5. Performance"))
    (expect-visible (test-id "toc:roc-signals-field-guide"))
    (expect-visible (test-id "toc:performance"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    ; One patch per outline row label, plus the checkbox itself; nothing else moves.
    (expect-metric-delta-at-most patches_emitted 6)
    (check (label "Number the outline"))
    (expect-checked (label "Number the outline") true)
    (expect-visible (text "1. Roc Signals Field Guide"))
    (expect-visible (text "5. Performance"))
  )
)
