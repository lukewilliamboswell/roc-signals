(test "After the previous spec dropped its root the native host has no retained File handle"
  (steps
    (expect-files 0)
    (expect-text (test-id "table-rows") "table rows 0")
  ))
