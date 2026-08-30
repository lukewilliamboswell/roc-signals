(test "Spreadsheet lite — B2 > D2 > D5 > D6 > D7 > D8 and B2 > B5 > (F5, D5 already covered)"
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

    ; B2 > D2 > D5 > D6 > D7 > D8 and B2 > B5 > (F5, D5 already covered)
    (expect-value (label "D2") "2800")
    (expect-value (label "B5") "2150")
    (expect-value (label "D5") "4400")
    (expect-value (label "F5") "4400")
    (expect-value (label "D6") "440")
    (expect-value (label "D7") "4840")
    (expect-value (label "D8") "1210")
    ; Cells that do not depend on B2 are untouched.
    (expect-value (label "C2") "1300")
    (expect-value (label "B3") "400")
    (expect-value (label "C3") "800")
    (expect-value (label "D3") "1200")
    (expect-value (label "D4") "400")
    (expect-value (label "C12") "7")
    (expect-value (label "A1") "Item")
    ; Work done for this edit. The outer grid re-diffs its 12 row keys, and only
    ; the five rows that actually changed (2, 5, 6, 7, 8) re-diff their 8 cells:
    ; 12 + 5 * 8 = 52 reused rows. A sheet-wide recompute would be 12 + 12 * 8 = 108.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 52)
    ; One root record recompute: the single Signal.map that evaluates the workbook.
    (expect-metric-delta dirty_source_roots 1)
    ; Nine value writes: the eight cells whose displayed value changed (B2, D2, B5,
    ; D5, F5, D6, D7, D8) plus the formula bar. No other cell is written.
    (expect-metric-delta set_value 9)
    (expect-metric-delta set_metadata 0)
    ; Only the rows whose bindings actually changed are refreshed, not the whole
    ; grid; restoring the old value below refreshes none at all.
    (expect-metric-delta bind_event 30)
    ; Restoring the old value restores every dependent.
    (mark-metrics)
    (fill (label "B2") "1200")
    (expect-metric-delta bind_event 0)
    (expect-metric-delta rows_reused 52)
    (expect-value (label "D2") "2500")
    (expect-value (label "D8") "1127.5")
    (blur (label "B2"))
  )
)
