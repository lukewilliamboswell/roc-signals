(test "Spreadsheet lite — editing a cell nothing depends on"
  (steps
    ; Given the state established by earlier scenarios
    (focus (label "D2"))
    (fill (label "Formula") "=B2+C2+100")
    (fill (label "Formula") "=B2+C2")
    (blur (label "D2"))
    (focus (label "D5"))
    (blur (label "D5"))
    (focus (label "F5"))
    (blur (label "F5"))
    (focus (label "B2"))
    (mark-metrics)
    (fill (label "B2") "1500")
    (mark-metrics)
    (fill (label "B2") "1200")
    (blur (label "B2"))

    ; editing a cell nothing depends on

    (focus (label "C12"))
    (mark-metrics)
    (fill (label "C12") "9")
    (expect-value (label "C12") "9")
    (expect-value (label "B12") "5")
    (expect-value (label "D7") "4510")
    (expect-value (label "A1") "Item")
    ; Only row 12 was re-diffed: 12 outer rows plus its 8 cells.
    (expect-metric-delta rows_reused 20)
    (expect-metric-delta dirty_source_roots 1)
    (expect-metric-delta set_value 2)
    (expect-metric-delta bind_event 0)
    (expect-metric-delta-at-most patches_emitted 4)
    (fill (label "C12") "7")
    (blur (label "C12"))
  )
)
