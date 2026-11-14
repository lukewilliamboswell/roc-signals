(test "dbg observes a handler without changing its result"
  (expect-text (test-id "count") "0")
  (click (role "button" "Add one"))
  (expect-text (test-id "count") "1"))
