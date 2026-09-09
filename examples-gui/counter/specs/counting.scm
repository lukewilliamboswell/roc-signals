(test "Counter propagates events through the shared engine"
  (steps
    (expect-visible (text "Count: 0"))
    (click (role button :name "Increment"))
    (expect-visible (text "Count: 1"))
    (click (role button :name "Increment"))
    (expect-visible (text "Count: 2"))
    (click (role button :name "Decrement"))
    (expect-visible (text "Count: 1"))
    (click (role button :name "Reset"))
    (expect-visible (text "Count: 0"))))
