(test "Spreadsheet lite — initial mount"
  (steps
    ; initial mount

    (expect-visible (role heading :name "Spreadsheet Lite"))
    (expect-visible (role region :name "Formula bar"))
    (expect-visible (role region :name "Sheet controls"))
    (expect-visible (role region :name "Sheet grid"))
    (expect-visible (role region :name "Row 1"))
    (expect-visible (role region :name "Row 11"))
    (expect-visible (role region :name "Row 12"))
    ; Header row of literals.
    (expect-value (label "A1") "Item")
    (expect-value (label "B1") "Q1")
    (expect-value (label "C1") "Q2")
    (expect-value (label "D1") "Total")
    (expect-value (label "E1") "")
    (expect-value (label "F1") "Checks")
    ; Literals and one-hop formulas.
    (expect-value (label "A2") "Rent")
    (expect-value (label "B2") "1200")
    (expect-value (label "C2") "1300")
    (expect-value (label "D2") "2500")
    (expect-value (label "B3") "400")
    (expect-value (label "C3") "800")
    (expect-value (label "D3") "1200")
    (expect-value (label "B4") "250")
    (expect-value (label "C4") "150")
    (expect-value (label "D4") "400")
    ; SUM over a column range and over a rectangle.
    (expect-value (label "B5") "1850")
    (expect-value (label "C5") "2250")
    (expect-value (label "D5") "4100")
    (expect-value (label "F5") "4100")
    ; Chains two and three hops deep, including a fractional literal and division.
    (expect-value (label "D6") "410")
    (expect-value (label "D7") "4510")
    (expect-value (label "B8") "4")
    (expect-value (label "D8") "1127.5")
    ; Operator precedence, parentheses, and non-integer division.
    (expect-value (label "F2") "14")
    (expect-value (label "F3") "20")
    (expect-value (label "F4") "2.5")
    ; Errors: divide by zero, a reference to a cell that itself errors, and a cycle.
    (expect-value (label "B9") "#DIV/0!")
    (expect-value (label "C9") "#DIV/0!")
    (expect-value (label "B10") "#CYCLE!")
    (expect-value (label "C10") "#CYCLE!")
    ; A formula referencing an empty cell treats it as zero.
    (expect-value (label "B12") "5")
    (expect-value (label "C12") "7")
    ; An entirely empty row still renders.
    (expect-value (label "A11") "")
    (expect-value (label "H12") "")
    ; Kind attributes drive presentation without a separate stored flag.
    (expect-attr (label "D2") data-kind "number")
    (expect-attr (label "A2") data-kind "text")
    (expect-attr (label "B9") data-kind "error")
    (expect-attr (label "A11") data-kind "empty")
    ; Status line: a three-way fan-in of selection, grid mode, and error count.
    (expect-text (test-id "stat-selected") "A1")
    (expect-text (test-id "stat-mode") "Values")
    (expect-text (test-id "status-line") "4")
    ; Formula bar for the initially selected cell.
    (expect-value (label "Formula") "Item")
    (expect-text (test-id "bar-cell") "A1")
    (expect-text (test-id "bar-source") "Item")
    (expect-text (test-id "bar-value") "Item")
    (expect-text (test-id "bar-depends") "none")
    (expect-text (test-id "bar-mode") "Showing value")
  )
)
