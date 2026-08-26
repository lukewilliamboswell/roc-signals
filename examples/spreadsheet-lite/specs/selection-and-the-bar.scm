(test "Spreadsheet lite — selection and the bar"
  (steps
    ; selection and the bar

    (focus (label "D2"))
    (expect-text (test-id "bar-cell") "Cell: D2")
    (expect-text (test-id "bar-mode") "Mode: editing")
    (expect-value (label "Formula") "=B2+C2")
    (expect-text (test-id "bar-source") "Source: =B2+C2")
    (expect-text (test-id "bar-value") "Value: 2500")
    (expect-text (test-id "bar-depends") "Depends on: B2, C2")
    (expect-text (test-id "status-line") "Selected: D2 | Grid mode: values | Errors: 4")
    ; The grid keeps showing computed values; the bar is where the formula lives.
    (expect-value (label "D2") "2500")
    (expect-value (label "D3") "1200")
    ; The formula bar writes the sheet while atomically reading the independent
    ; cursor state to choose the target cell.
    (fill (label "Formula") "=B2+C2+100")
    (expect-value (label "Formula") "=B2+C2+100")
    (expect-text (test-id "bar-value") "Value: 2600")
    (fill (label "Formula") "=B2+C2")
    (expect-text (test-id "bar-value") "Value: 2500")
    (blur (label "D2"))
    (expect-text (test-id "bar-mode") "Mode: showing value")
    (expect-value (label "Formula") "2500")
    (expect-value (label "D2") "2500")
    ; A SUM cell reports every member of its range as a dependency.
    (focus (label "D5"))
    (expect-text (test-id "bar-depends") "Depends on: D2, D3, D4")
    (blur (label "D5"))
    (focus (label "F5"))
    (expect-text (test-id "bar-depends") "Depends on: B2, C2, B3, C3, B4, C4")
    (blur (label "F5"))
  )
)
