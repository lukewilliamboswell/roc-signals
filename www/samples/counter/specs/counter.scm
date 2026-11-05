(test "the counter counts both ways"
  (steps
    (expect-text (test-id "count") "0")
    (click (role button :name "Increment"))
    (click (role button :name "Increment"))
    (expect-text (test-id "count") "2")
    (click (role button :name "Decrement"))
    (expect-text (test-id "count") "1")))
