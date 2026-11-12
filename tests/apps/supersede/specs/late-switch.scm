(test "Supersede — a state in a switch case selected after mount refreshes its readers"
  (steps
    (click (role button :name "Counting case"))
    (click (role button :name "Inc case"))
    (expect-text (test-id "case") "case 1")
  )
)
