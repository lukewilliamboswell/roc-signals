; A round trip back to the sheet it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated.
(test "Spreadsheet Lite — round trip: an edit, a reorder, a filter and a mode, each undone"
  (steps
    (mark-metrics)
    (fill (label "B2") "1500")
    (fill (label "B2") "1200")
    (click (role button :name "Reverse row order"))
    (click (role button :name "Top to bottom"))
    (click (role button :name "Hide empty rows"))
    (click (role button :name "Show all rows"))
    (click (role button :name "Show formulas"))
    (click (role button :name "Show values"))
  )
)
