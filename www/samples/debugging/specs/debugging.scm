(test "dbg observes a handler without changing its result"
  (steps
    (expect-text (test-id "count") "0")
    (click (role button :name "Add one"))
    (expect-text (test-id "count") "1")
  )
)
