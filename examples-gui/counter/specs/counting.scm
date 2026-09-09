(test "Counter propagates events through the shared engine"
  (steps
    (expect-text (test-id "count") "0")
    (click (role button :name "Increment"))
    (expect-text (test-id "count") "1")
    (click (role button :name "Increment"))
    (expect-text (test-id "count") "2")
    (click (role button :name "Decrement"))
    (expect-text (test-id "count") "1")
    (click (role button :name "Reset"))
    (expect-text (test-id "count") "0")))
