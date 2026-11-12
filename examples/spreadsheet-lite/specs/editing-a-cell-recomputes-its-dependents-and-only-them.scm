(test "Spreadsheet lite — editing a cell recomputes its dependents and only them"
  (steps
    ; Bring the page to the state this spec starts from.
    (focus (label "D2"))
    (fill (label "Formula") "=B2+C2+100")
    (fill (label "Formula") "=B2+C2")
    (blur (label "D2"))
    (focus (label "D5"))
    (blur (label "D5"))
    (focus (label "F5"))
    (blur (label "F5"))

    ; editing a cell recomputes its dependents and only them

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
    ; Work done for this edit. The edit writes the five rows whose cells
    ; changed (2, 5, 6, 7, 8), and the grid, a view of the sheet's table,
    ; wakes those rows and no others. Each matches its 8 cells by address:
    ; 5 * 8 = 40 reused rows, where matching every row's cells would be
    ; 12 * 8 = 96. Of those 40 cells the 8 whose value changed are woken:
    ; with the 5 rows, 13 rows updated.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 40)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 13)
    ; One cell of the store is written: the sheet's table.
    (expect-metric-delta dirty_source_roots 1)
    ; Nine value writes: the eight cells whose displayed value changed (B2, D2, B5,
    ; D5, F5, D6, D7, D8) plus the formula bar. No other cell is written.
    (expect-metric-delta set_value 9)
    (expect-metric-delta set_metadata 0)
    ; Every row and cell stays mounted, so no event listener is bound.
    (expect-metric-delta bind_event 0)
    ; Restoring the old value restores every dependent.
    (mark-metrics)
    (fill (label "B2") "1200")
    (expect-metric-delta bind_event 0)
    (expect-metric-delta rows_reused 40)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 13)
    (expect-value (label "D2") "2500")
    (expect-value (label "D8") "1127.5")
    (blur (label "B2"))
  )
)
