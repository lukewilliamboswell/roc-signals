(test "Spreadsheet lite — selection and the bar"
  (steps
    ; selection and the bar

    (focus (label "D2"))
    (expect-text (test-id "bar-cell") "D2")
    (expect-text (test-id "bar-mode") "Editing")
    (expect-value (label "Formula") "=B2+C2")
    (expect-text (test-id "bar-source") "=B2+C2")
    (expect-text (test-id "bar-value") "2500")
    (expect-text (test-id "bar-depends") "B2, C2")
    (expect-text (test-id "stat-selected") "D2")
    (expect-text (test-id "stat-mode") "Values")
    (expect-text (test-id "status-line") "4")
    ; The grid keeps showing computed values; the bar is where the formula lives.
    (expect-value (label "D2") "2500")
    (expect-value (label "D3") "1200")
    ; The formula bar writes the sheet while atomically reading the independent
    ; cursor state to choose the target cell.
    (fill (label "Formula") "=B2+C2+100")
    (expect-value (label "Formula") "=B2+C2+100")
    (expect-text (test-id "bar-value") "2600")
    (fill (label "Formula") "=B2+C2")
    (expect-text (test-id "bar-value") "2500")
    (blur (label "D2"))
    (expect-text (test-id "bar-mode") "Showing value")
    (expect-value (label "Formula") "2500")
    (expect-value (label "D2") "2500")
    ; A SUM cell reports every member of its range as a dependency.
    (focus (label "D5"))
    (expect-text (test-id "bar-depends") "D2, D3, D4")
    (blur (label "D5"))
    (focus (label "F5"))
    (expect-text (test-id "bar-depends") "B2, C2, B3, C3, B4, C4")
    (blur (label "F5"))
  )
)
