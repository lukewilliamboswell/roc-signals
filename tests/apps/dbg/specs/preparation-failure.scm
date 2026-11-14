(test "a preparation debug observation leaves its typed failure intact"
  (steps
    (expect-text (test-id "count") "0")
    (click (role button :name "Empty prefix"))
    (run-effect 2)
    (expect-text (test-id "answer") "empty prefix")
    (expect-text (test-id "count") "-4")
  )
)
