(test "Recursive Ui.switch builds only the selected case"
  (steps
    ; Eager construction would recurse forever. Reaching this leaf proves each
    ; retained builder was invoked only after its parent case was selected.
    (expect-visible (role region :name "Recursive switch"))
    (expect-text (test-id "recursive-leaf") "leaf")
    (expect-text (role region :name "Recursive switch") "Recursive switchlevel 3level 2level 1leafGrowReset")
    (click (role button :name "Grow"))
    (expect-text (role region :name "Recursive switch") "Recursive switchlevel 4level 3level 2level 1leafGrowReset")
    (click (role button :name "Reset"))
    (expect-text (role region :name "Recursive switch") "Recursive switchlevel 1leafGrowReset")
  )
)
